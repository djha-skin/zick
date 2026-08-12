;;;; src/package.lisp
;;;;
;;;; Package install, removal, and verification, on top of the
;;;; session/db layers.
;;;;
;;;; Ported from zic's src/zic/package.clj.  zic's options maps become
;;;; plists, its hash-map results become alists (results grouped by a
;;;; keyword) and plists (file info), and its immutable datalevin
;;;; mutations become the pure store threading of db: functions: the
;;;; session saves whatever store its thunk returns, so install-package
;;;; returns the store while remove-package captures its presentation
;;;; in a closure and lets the session persist the store.

(defpackage #:com.djhaskin.zick/package
  (:use #:cl)
  (:import-from #:com.djhaskin.zick/db)
  (:import-from #:com.djhaskin.zick/fs)
  (:import-from #:com.djhaskin.zick/session)
  (:import-from #:com.djhaskin.svers)
  (:import-from #:org.shirakumo.zippy)
  (:import-from #:fset)
  (:import-from #:gmap)
  (:import-from #:uiop)
  (:import-from #:cl-ppcre)
  (:local-nicknames
    (#:db #:com.djhaskin.zick/db)
    (#:fs #:com.djhaskin.zick/fs)
    (#:session #:com.djhaskin.zick/session)
    (#:svers #:com.djhaskin.svers)
    (#:z #:org.shirakumo.zippy)
    (#:f #:fset))
  (:export
    ;; Queries
    #:get-package-files
    #:verify-package-files
    #:get-package-info
    #:get-package-dependees
    #:get-package-dependers
    ;; Downloading
    #:download-package
    ;; Installation
    #:decide-config-fate
    #:package-file-conflicts
    #:config-and-upgrade-precautions
    #:install-package
    ;; Removal
    #:remove-without-cascade-internal
    #:remove-package
    ;; Graph linearization
    #:reachable-nodes
    #:sinks
    #:linearize))

(in-package #:com.djhaskin.zick/package)

;;; Grouping

(defun group-by (key-fn items)
  "Return ITEMS grouped by (KEY-FN ITEM) as an alist of (key . items)."
  (let (groups)
    (dolist (item items)
      (let* ((key (funcall key-fn item))
             (found (assoc key groups)))
        (if found
            (setf (cdr found) (cons item (cdr found)))
            (push (cons key (list item)) groups))))
    (nreverse groups)))

;;; Queries

(defun get-package-files (options)
  "Return the presented files of the package named by :PACKAGE-NAME
   in the database at :DB-CONNECTION-STRING, or nil when the package
   is not installed."
  (session:with-database
    (getf options :db-connection-string)
    (lambda (store)
      (let ((pkg-id (db:package-id store (getf options :package-name))))
        (when pkg-id
          (db:package-files store pkg-id))))))

(defun verify-package-files (options)
  "Verify the installed files of the package named by :PACKAGE-NAME
   against the project rooted at :ROOT-PATH.

   Returns an alist of result keyword to the file info plists (each
   with :PATH) having that result; results of :correct are omitted.
   Signals an error when the package is not installed."
  (session:with-database
    (getf options :db-connection-string)
    (lambda (store)
      (let ((pkg-id (db:package-id store (getf options :package-name))))
        (if (null pkg-id)
            (error "Could not extract file information from database.~%~\
                    Perhaps the database is missing or the project ~\
                    path is incorrect.")
            (let* ((files (db:package-files store pkg-id))
                   (root-path (getf options :root-path))
                   (verified
                     (gmap:gmap (:result list)
                       (lambda (x)
                         (list* :path (getf x :path)
                                (fs:verify root-path x)))
                       (:arg :seq files))))
              (loop for (result . infos)
                    in (remove-if
                         (lambda (group)
                           (eq (car group) :correct))
                         (group-by (lambda (z) (getf z :result)) verified))
                    collect (cons result
                                  (gmap:gmap (:result list)
                                    (lambda (y)
                                      (let ((copy (copy-list y)))
                                        (remf copy :result)
                                        copy))
                                    (:arg :list infos))))))))))

(defun get-package-info (options)
  "Return the presented info of the package named by :PACKAGE-NAME in
   the database at :DB-CONNECTION-STRING, or nil."
  (session:with-database
    (getf options :db-connection-string)
    (lambda (store)
      (db:package-info store (getf options :package-name)))))

(defun get-package-dependees (options)
  "Return the presented info of the packages the package named by
   :PACKAGE-NAME depends on, or nil."
  (session:with-database
    (getf options :db-connection-string)
    (lambda (store)
      (db:package-dependees store (getf options :package-name)))))

(defun get-package-dependers (options)
  "Return the presented info of the packages that depend on the
   package named by :PACKAGE-NAME, or nil."
  (session:with-database
    (getf options :db-connection-string)
    (lambda (store)
      (db:package-dependers store (getf options :package-name)))))

;;; Downloading

(defun download-package (options)
  "Download the zip archive of the package described by OPTIONS to
   the :STAGING-PATH directory and return it as an open zippy
   zip-file (the caller closes it).

   The file name is the last path component of :PACKAGE-LOCATION, or
   PACKAGE-NAME-PACKAGE-VERSION.zip when it has none.  Signals an
   error unless :PACKAGE-NAME, :PACKAGE-VERSION, and :PACKAGE-LOCATION
   are all given."
  (let ((package-name (getf options :package-name))
        (package-version (getf options :package-version))
        (package-location (getf options :package-location))
        (staging-path (getf options :staging-path)))
    (unless (and package-name package-version package-location)
      (error "Package name, version, and location must all be given."))
    (let* ((fname
             (multiple-value-bind (start end reg-starts reg-ends)
                                  (cl-ppcre:scan "/([^/]+)$" package-location)
               (declare (ignore start end))
               (if reg-starts
                   (subseq package-location
                           (aref reg-starts 0) (aref reg-ends 0))
                   (format nil "~a-~a.zip"
                           package-name package-version))))
           (staging-dir (uiop:ensure-directory-pathname
                          (if (stringp staging-path)
                              (uiop:parse-native-namestring staging-path)
                              staging-path)))
           (download-dest (merge-pathnames fname staging-dir)))
      (ensure-directories-exist staging-dir)
      (fs:download package-location download-dest
                   (getf options :download-authorizations)
                   (getf options :insecure))
      (z:open-zip-file download-dest))))

;;; Installation

(defun decide-config-fate (old current nw)
  "Decide what to do with a config file given its checksums: :INSTALL
   (write the new one), :PUT-ASIDE (keep the current one, stash the
   new one), or :DO-NOTHING.

   OLD is the checksum of the installed version, CURRENT of the file
   on disk, and NW of the archive entry."
  (cond
    ((null current) :install)
    ((null old) :put-aside)
    ((null nw) :do-nothing)
    ((and (not (equal old current))
          (not (equal nw current))
          (not (equal old nw)))
     :put-aside)
    ((and (not (equal old current))
          (equal nw old))
     :do-nothing)
    (t :install)))

(defun path-checksum-pair (file)
  "Return (PATH . CHECKSUM) of the presented file plist FILE."
  (cons (getf file :path) (getf file :checksum)))

(defun entry-path (entry)
  "Return the :PATH of the archive entry plist ENTRY, or nil when it
   is a directory."
  (unless (getf entry :is-directory)
    (getf entry :path)))

(defun package-file-conflicts (store package-name new-files)
  "Return the entries of NEW-FILES (plists with :PATH and
   :IS-DIRECTORY) that are not directories and are already owned in
   STORE by a package other than PACKAGE-NAME, each annotated with
   :PACKAGE naming its owner."
  (gmap:gmap (:result list :filterp :id)
    (lambda (rec)
      (unless (getf rec :is-directory)
        (let ((owner (db:owned-by-p store (getf rec :path))))
          (when (and owner (not (string= package-name owner)))
            (list* :package owner rec)))))
    (:arg :seq new-files)))

(defun config-group-paths (config-decisions fate)
  "Return the fset set of paths whose config decision is FATE.

   CONFIG-DECISIONS is an alist of (fate . path) pairs."
  (f:convert 'fset:set
             (mapcar #'cdr (cdr (assoc fate config-decisions)))))

(defun upgrade-existing-package (options store downloaded-zip zip-files)
  "Compute the upgrade precautions for the already-installed package
   described by OPTIONS and prepare the project.

   Returns (values PRECAUTIONS UPDATED-STORE).  PRECAUTIONS is a plist
   with :PUT-ASIDE and :DO-NOTHING (fset sets of paths) and
   :CONFIG-SUMS (an fset map of path to old checksum).  UPDATED-STORE
   has the existing package's files and uses removed.  Signals an
   error on in-place replacement or downgrade unless allowed.

   Current file checksums are computed against :ROOT-PATH (zic
   resolves them against the working directory; :ROOT-PATH is where
   the project's files live)."
  (let* ((package-name (getf options :package-name))
         (package-version (getf options :package-version))
         (root-path (getf options :root-path))
         (exist-pkg (db:package-info store package-name))
         (exist-pkg-id (getf exist-pkg :name))
         (exist-pkg-vers (getf exist-pkg :version))
         (old-files (group-by (lambda (f) (getf f :class))
                              (db:package-files store exist-pkg-id)))
         (old-config-files (cdr (assoc :config-file old-files)))
         (old-config-pairs
           (gmap:gmap (:result list)
             #'path-checksum-pair
             (:arg :list old-config-files)))
         (old-config-sums (f:convert 'fset:map old-config-pairs))
         (old-config-fset
           (f:convert 'fset:set (mapcar #'car old-config-pairs)))
         (zip-path-fset
           (f:convert 'fset:set
                      (gmap:gmap (:result list :filterp :id)
                        #'entry-path
                        (:arg :seq zip-files))))
         (new-config-fset
           (f:intersection
             zip-path-fset
             (f:convert 'fset:set
                        (db:zick-paths (getf options :package-metadata)
                                       :config-files))))
         (contig-config-files
           (f:intersection old-config-fset new-config-fset))
         (contig-config-old-sums
           (f:reduce
             (lambda (acc cf)
               (f:with acc cf (f:lookup old-config-sums cf)))
             contig-config-files
             :initial-value (f:empty-map)))
         (new-checksums
           (fs:archive-entry-checksums
             downloaded-zip
             (lambda (name) (f:contains? new-config-fset name))))
         (current-checksums
           (f:reduce
             (lambda (acc conf-path)
               (f:with acc conf-path
                 (fs:file-sha256
                   (merge-pathnames conf-path root-path))))
             new-config-fset
             :initial-value (f:empty-map)))
         (config-decisions
           (group-by
             #'car
             (gmap:gmap (:result list)
               (lambda (x)
                 (cons
                   (decide-config-fate
                     (f:lookup old-config-sums x)
                     (f:lookup current-checksums x)
                     (f:lookup new-checksums x))
                   x))
               (:arg :seq new-config-fset))))
         (incontig-configs
           (f:set-difference old-config-fset contig-config-files))
         (put-aside-paths
           (config-group-paths config-decisions :put-aside))
         (do-nothing-paths
           (config-group-paths config-decisions :do-nothing)))
    (when (and (not (getf options :allow-inplace))
               (zerop (svers:debian-vercmp exist-pkg-vers package-version)))
      (error "Option `allow-inplace` is disabled and in-place ~
              replacement detected."))
    (when (and (not (getf options :allow-downgrades))
               (plusp (svers:debian-vercmp exist-pkg-vers package-version)))
      (error "Option `allow-downgrades` is disabled and ~
              downgrade detected."))
    (fs:backup-all root-path
                   (f:convert 'list incontig-configs)
                   (format nil "~a.~a.backup"
                           package-name exist-pkg-vers))
    (fs:remove-files
      root-path
      (gmap:gmap (:result list)
        #'entry-path
        (:arg :list (cdr (assoc :normal-file old-files)))))
    (let* ((updated-store
             (db:remove-uses
               (db:remove-files store exist-pkg-id)
               exist-pkg-id)))
      (values
        (list :put-aside put-aside-paths
              :do-nothing do-nothing-paths
              :config-sums contig-config-old-sums)
        updated-store))))

(defun config-and-upgrade-precautions (options store downloaded-zip zip-files)
  "Decide how to handle the files of the package described by OPTIONS
   given that it is already installed, and prepare the project.

   Returns (values PRECAUTIONS UPDATED-STORE); see
   upgrade-existing-package for the installed case.  When the package
   is not yet installed, PRECAUTIONS names the config files already
   present on disk for :PUT-ASIDE and UPDATED-STORE is unchanged."
  (let ((root-path (getf options :root-path))
        (config-paths
          (db:zick-paths (getf options :package-metadata) :config-files)))
    (if (db:package-info store (getf options :package-name))
        (upgrade-existing-package
          options store downloaded-zip zip-files)
        (values
          (list :put-aside
                (f:convert 'fset:set
                           (gmap:gmap (:result list :filterp :id)
                             (lambda (p)
                               (when (uiop:file-exists-p
                                       (merge-pathnames p root-path))
                                 p))
                             (:arg :seq config-paths))))
          store))))

(defun install-package-from-zip (options store downloaded-zip)
  "Unpack DOWNLOADED-ZIP for the package described by OPTIONS into
   the project rooted at :ROOT-PATH, returning (values PACKAGE-FILES
   UPDATED-STORE) for add-package.  DOWNLOADED-ZIP is closed by the
   caller."
  (let* ((package-name (getf options :package-name))
         (package-version (getf options :package-version))
         (package-metadata (getf options :package-metadata))
         (zip-files (fs:archive-contents downloaded-zip))
         (ghost-files (db:zick-paths package-metadata :ghost-files))
         (new-files
           (append
             zip-files
             (gmap:gmap (:result list)
               (lambda (gf) (list :path gf :is-directory nil))
               (:arg :seq ghost-files))))
         (conflicts
           (package-file-conflicts store package-name new-files)))
    (when conflicts
      (error "Several files are already present in the project ~
              which are owned by other packages: ~a" conflicts))
    (multiple-value-bind (precautions updated-store)
                         (config-and-upgrade-precautions
                           options store downloaded-zip zip-files)
      (let ((package-files
              (fs:unpack
                downloaded-zip (getf options :root-path)
                :put-aside (getf precautions :put-aside)
                :put-aside-ending
                (format nil ".~a.~a.new" package-name package-version)
                :exclude (getf precautions :do-nothing)
                :exclude-sum-pool (getf precautions :config-sums))))
        (values package-files updated-store)))))

(defun install-with-download (options store dependency-ids)
  "Download and unpack the package described by OPTIONS, then
   add-package the unpacked files with DEPENDENCY-IDS.  Returns the
   updated store."
  (let ((downloaded-zip (download-package options)))
    (if (null downloaded-zip)
        (error "Package was not able to be downloaded.")
        (unwind-protect
            (multiple-value-bind (package-files updated-store)
                                 (install-package-from-zip
                                   options store downloaded-zip)
              (db:add-package updated-store options
                              package-files dependency-ids))
          (close downloaded-zip)))))

(defun install-package (options)
  "Install the package described by OPTIONS, returning the updated
   store (persisted by the session).

   With :DOWNLOAD-PACKAGE, downloads the archive named by
   :PACKAGE-LOCATION, unpacks it into the project rooted at
   :ROOT-PATH (putting aside and upgrading config files), and records
   the installed files; otherwise the package is only recorded.
   Signals an error when a :PACKAGE-DEPENDENCY is not installed or
   when an archive file is owned by another package."
  (session:with-zick-session
    (getf options :db-connection-string)
    (getf options :lock-path)
    (lambda (store)
      (let* ((dependencies
               (gmap:gmap (:result list)
                 (lambda (d)
                   (cons d (db:package-id store d)))
                 (:arg :seq (getf options :package-dependency))))
             (dependencies-status
               (group-by (lambda (pair)
                           (if (null (cdr pair)) :unmet :met))
                         dependencies)))
        (if (cdr (assoc :unmet dependencies-status))
            (error "Several dependencies are unmet: ~a"
                   (mapcar #'car (cdr (assoc :unmet dependencies-status))))
            (let ((dependency-ids
                    (mapcar #'cdr (cdr (assoc :met dependencies-status)))))
              (if (getf options :download-package)
                  (install-with-download options store dependency-ids)
                  (db:add-package store options '() dependency-ids))))))))

;;; Removal

(defun remove-without-cascade-internal (store package-info root-path)
  "Remove the package described by the presented plist PACKAGE-INFO
   from STORE and delete its files under ROOT-PATH (backing up its
   config files), returning the updated store."
  (let* ((package-name (getf package-info :name))
         (old-files (group-by (lambda (f) (getf f :class))
                              (db:package-files store package-name)))
         (config-paths
           (gmap:gmap (:result list :filterp :id)
             #'entry-path
             (:arg :list (cdr (assoc :config-file old-files)))))
         (normal-paths
           (gmap:gmap (:result list :filterp :id)
             #'entry-path
             (:arg :list (cdr (assoc :normal-file old-files))))))
    (fs:backup-all root-path config-paths
                   (format nil "~a.~a.backup"
                           package-name (getf package-info :version)))
    (fs:remove-files root-path normal-paths)
    (let ((store (db:remove-files store package-name)))
      (db:remove-package (db:remove-uses store package-name)
                         package-name))))

(defun remove-package (options)
  "Remove the package named by :PACKAGE-NAME and, with :CASCADE, the
   packages that depend on it.

   Returns the presented info of the removed packages, or nil if the
   package is not installed.  With :DRY-RUN the removal is computed
   but not performed.  Signals an error when other packages depend on
   the one to be removed and :CASCADE is not enabled."
  (let (removed)
    (session:with-zick-session
      (getf options :db-connection-string)
      (getf options :lock-path)
      (lambda (store)
        (let ((package-info (db:package-info store
                                             (getf options :package-name))))
          (if (null package-info)
              (progn (setf removed nil) store)
              (let* ((remove-ids
                       (linearize
                         (lambda (pid)
                           (db:dependers-by-id store pid))
                         (getf package-info :name)))
                     (remove-infos
                       (gmap:gmap (:result list)
                         (lambda (i)
                           (db:package-info-by-id store i))
                         (:arg :seq remove-ids))))
                (cond
                  ((getf options :cascade)
                   (setf removed remove-infos)
                   (if (getf options :dry-run)
                       store
                       (f:reduce
                         (lambda (acc pkg)
                           (remove-without-cascade-internal
                             acc pkg (getf options :root-path)))
                         remove-infos
                         :initial-value store)))
                  ((= 1 (length remove-ids))
                   (setf removed (list package-info))
                   (if (getf options :dry-run)
                       store
                       (remove-without-cascade-internal
                         store package-info (getf options :root-path))))
                  (t
                   (error "Packages which depend on the one in ~
                           question exist, cannot remove: ~{~a~^, ~}"
                          (remove (getf package-info :name)
                                  remove-ids :test #'string=)))))))))
    removed))

;;; Graph linearization

(defun reachable-nodes (gf node already-seen ignore)
  "Return ALREADY-SEEN extended with every node reachable from NODE
   via GF, skipping the nodes in IGNORE (they 'do not exist' for this
   run).  GF takes a node and returns the nodes reachable from it."
  (if (member node already-seen :test #'string=)
      already-seen
      (reduce (lambda (acc v)
                (reachable-nodes gf v acc ignore))
              (remove-if (lambda (n) (member n ignore :test #'string=))
                         (funcall gf node))
              :initial-value (cons node already-seen))))

(defun sinks (rnodes gf ignore)
  "Return the nodes of RNODES that have no neighbors outside IGNORE."
  (remove-if-not (lambda (x)
                   (null (remove-if (lambda (n)
                                      (member n ignore :test #'string=))
                                    (funcall gf x))))
                 rnodes))

(defun linearize (gf node)
  "Linearize the subgraph of GF reachable from NODE, sinks first, so
   that packages with no dependers are listed before the packages
   that depend on them.  A cycle is resolved by listing all the
   remaining nodes at once."
  (loop with ignore = '()
        with building = '()
        do (let* ((rnodes (reachable-nodes gf node '() ignore))
                  (snodes (sinks rnodes gf ignore)))
             (cond
               ((and (= 1 (length rnodes)) (member node rnodes
                                                   :test #'string=))
                (return (append building (list node))))
               ((null snodes)
                (return (append building (sort rnodes #'string<))))
               (t
                (setf ignore (append ignore snodes)
                      building (append building (sort snodes #'string<))))))))
