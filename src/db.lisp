;;;; src/db.lisp
;;;;
;;;; The zick package and file store: FSet persistent records
;;;; serialized as a single NRDL document in the .zick-db directory.
;;;;
;;;; Ported from zic's src/zic/db.clj.  Datalevin's entity refs become
;;;; explicit name keys resolved with FSet lookups: the store is a
;;;; package map (name -> package record) plus a file map (path -> file
;;;; record), each file record naming the package that owns it.
;;;;
;;;; Values live in FSet land throughout; fset:convert appears only at
;;;; the I/O boundary (slurp-store) and where caller-supplied data is
;;;; normalized on the way into a record (add-package).

(defpackage #:com.djhaskin.zick/db
  (:use #:cl)
  (:import-from #:com.djhaskin.nrdl)
  (:import-from #:fset)
  (:import-from #:gmap)
  (:import-from #:uiop)
  (:local-nicknames
    (#:f #:fset)
    (#:nrdl #:com.djhaskin.nrdl))
  (:export
    ;; Records
    #:make-store
    #:store
    #:store-p
    #:store-packages
    #:store-files
    #:make-package-record
    #:package-record
    #:package-record-name
    #:package-record-version
    #:package-record-location
    #:package-record-metadata
    #:package-record-is-source
    #:package-record-dependencies
    #:make-file
    #:file
    #:file-path
    #:file-size
    #:file-class
    #:file-checksum
    #:file-owner
    ;; Store lifecycle
    #:empty-store
    #:slurp-store
    #:save-store
    #:init-database
    ;; Queries
    #:package-id
    #:package-info
    #:package-info-by-id
    #:package-files
    #:owned-by-p
    #:dependers-by-id
    #:package-dependers
    #:package-dependees
    #:used-somewhere-p
    ;; Mutations
    #:add-package
    #:insert-file
    #:insert-use
    #:remove-package
    #:remove-files
    #:remove-uses
    ;; Helpers
    #:clean-for-insert
    #:file-class-p
    #:zick-paths))

(in-package #:com.djhaskin.zick/db)

;;; Records

(defstruct store
  "The whole zick database: packages keyed by name and files keyed by
   path, each file naming the package that owns it."
  (packages (f:empty-map))
  (files (f:empty-map)))

(defstruct package-record
  "An installed package.  DEPENDENCIES is an FSet set of package
   names; METADATA is an FSet map (or nil)."
  (name nil)
  (version nil)
  (location nil)
  (metadata nil)
  (is-source nil)
  (dependencies (f:empty-set)))

(defstruct file
  "A file installed by a package, keyed by PATH.  OWNER is the name of
   the owning package."
  (path nil)
  (size nil)
  (class nil)
  (checksum nil)
  (owner nil))

;;; NRDL serialization
;;;
;;; The records serialize as NRDL objects.  FSet collections are
;;; emitted natively (NRDL handles sets, seqs, and maps), so the write
;;; path needs no conversion; the read path converts the reader's FSet
;;; seqs back into the records' set/map slots.

(defmethod nrdl:emit-nrdl-struct (strm (val store) pretty-indent indented-at
                                       &key json-mode)
  "Serialize a STORE as an NRDL object with :PACKAGES and :FILES."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash :packages ht) (store-packages val))
    (setf (gethash :files ht) (store-files val))
    (nrdl:inject-object strm ht pretty-indent indented-at
                        :json-mode json-mode)))

(defmethod nrdl:emit-nrdl-struct (strm (val package-record) pretty-indent
                                       indented-at &key json-mode)
  "Serialize a PACKAGE-RECORD as an NRDL object."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash :name ht) (package-record-name val))
    (setf (gethash :version ht) (package-record-version val))
    (setf (gethash :location ht) (package-record-location val))
    (setf (gethash :metadata ht) (package-record-metadata val))
    (setf (gethash :is-source ht) (package-record-is-source val))
    (setf (gethash :dependencies ht) (package-record-dependencies val))
    (nrdl:inject-object strm ht pretty-indent indented-at
                        :json-mode json-mode)))

(defmethod nrdl:emit-nrdl-struct (strm (val file) pretty-indent indented-at
                                       &key json-mode)
  "Serialize a FILE as an NRDL object."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash :path ht) (file-path val))
    (setf (gethash :size ht) (file-size val))
    (setf (gethash :class ht) (file-class val))
    (setf (gethash :checksum ht) (file-checksum val))
    (setf (gethash :owner ht) (file-owner val))
    (nrdl:inject-object strm ht pretty-indent indented-at
                        :json-mode json-mode)))

;;; Record rebuilding (read side)

(defun lookup-key (map key)
  "Return the value of KEY in the FSet map MAP, or nil."
  (when map
    (nth-value 0 (f:lookup map key))))

(defun package-from-data (data)
  "Rebuild a PACKAGE-RECORD from parsed NRDL data (an FSet map)."
  (make-package-record
    :name (lookup-key data :name)
    :version (lookup-key data :version)
    :location (lookup-key data :location)
    :metadata (lookup-key data :metadata)
    :is-source (lookup-key data :is-source)
    ;; NRDL reads arrays back as FSet seqs; the record invariant is a
    ;; set of dependency names, so this conversion belongs at the I/O
    ;; boundary.
    :dependencies (f:convert 'fset:set (lookup-key data :dependencies))))

(defun file-from-data (data)
  "Rebuild a FILE record from parsed NRDL data (an FSet map)."
  (make-file
    :path (lookup-key data :path)
    :size (lookup-key data :size)
    :class (lookup-key data :class)
    :checksum (lookup-key data :checksum)
    :owner (lookup-key data :owner)))

(defun store-from-data (data)
  "Rebuild a STORE record from parsed NRDL data (an FSet map)."
  (let ((packages (or (lookup-key data :packages) (f:empty-map)))
        (files (or (lookup-key data :files) (f:empty-map))))
    (make-store
      :packages (f:reduce
                  (lambda (acc name pkg-data)
                    (f:with acc name (package-from-data pkg-data)))
                  packages
                  :initial-value (f:empty-map))
      :files (f:reduce
               (lambda (acc path file-data)
                 (f:with acc path (file-from-data file-data)))
               files
               :initial-value (f:empty-map)))))

;;; Store lifecycle

(defun empty-store ()
  "Return a new, empty STORE."
  (make-store))

(defun slurp-store (path)
  "Load the STORE from the NRDL file at PATH, or return an empty
   STORE if no such file exists."
  (if (uiop:file-exists-p path)
      (with-open-file (stream path :direction :input)
        (store-from-data (nrdl:to-fset (nrdl:parse-from stream))))
      (empty-store)))

(defun save-store (path store)
  "Write STORE to the NRDL file at PATH, atomically (temp file +
   rename).  Creates the parent directory if needed, mirroring
   datalevin's lazy creation on open."
  (ensure-directories-exist path)
  (let ((tmp (uiop:parse-native-namestring
               (format nil "~a.~d.tmp" path (random 1000000)))))
    (unwind-protect
        (progn
          (with-open-file (stream tmp :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create)
            (nrdl:generate-to stream store :pretty-indent 2))
          (uiop:rename-file-overwriting-target tmp path))
      (uiop:delete-file-if-exists tmp))))

(defun init-database (path)
  "Initialize the database at PATH.  A no-op: the store is created
   lazily on first use."
  (declare (ignore path))
  nil)

;;; Queries

(defun package-id (store package-name)
  "Return the id of the package named PACKAGE-NAME (its name), or
   nil."
  (when (map-contains-p (store-packages store) package-name)
    package-name))

(defun map-contains-p (map key)
  "Return non-nil if KEY is a key of the FSet map MAP."
  (nth-value 1 (f:lookup map key)))

(defun package-info-by-id (store pkg-id)
  "Return the presented info of package PKG-ID, or nil."
  (when pkg-id
    (let ((pkg (lookup-key (store-packages store) pkg-id)))
      (when pkg
        (present-package pkg)))))

(defun package-info (store package-name)
  "Return the presented info of the package named PACKAGE-NAME."
  (package-info-by-id store (package-id store package-name)))

(defun package-files (store pkg-id)
  "Return the presented files installed by package PKG-ID."
  (gmap:gmap (:result list :filterp :id)
    (lambda (path file)
      (declare (ignore path))
      (when (string= (file-owner file) pkg-id)
        (present-file file)))
    (:arg :map (store-files store))))

(defun owned-by-p (store file)
  "Return the name of the package owning FILE, or nil."
  (let ((rec (lookup-key (store-files store) file)))
    (when rec
      (file-owner rec))))

(defun dependers-by-id (store pkg-id)
  "Return the ids of packages that depend on PKG-ID."
  (gmap:gmap (:result list :filterp :id)
    (lambda (name pkg)
      (when (f:contains? (package-record-dependencies pkg) pkg-id)
        name))
    (:arg :map (store-packages store))))

(defun package-dependers (store package-name)
  "Return the presented info of packages that depend on PACKAGE-NAME."
  (when (package-id store package-name)
    (gmap:gmap (:result list :filterp :id)
      (lambda (name pkg)
        (declare (ignore name))
        (when (f:contains? (package-record-dependencies pkg) package-name)
          (present-package pkg)))
      (:arg :map (store-packages store)))))

(defun package-dependees (store package-name)
  "Return the presented info of packages PACKAGE-NAME depends on."
  (let ((pkg (lookup-key (store-packages store) package-name)))
    (when pkg
      (gmap:gmap (:result list :filterp :id)
        (lambda (dep-name)
          (let ((dep (lookup-key (store-packages store) dep-name)))
            (when dep
              (present-package dep))))
        (:arg :seq (package-record-dependencies pkg))))))

(defun used-somewhere-p (store package-name)
  "Return non-nil when some package in STORE depends on
   PACKAGE-NAME."
  (not (null (dependers-by-id store package-name))))

;;; Mutations

(defun clean-for-insert (plist)
  "Return PLIST with pairs whose value is nil removed."
  (loop for (k v) on plist by #'cddr
        unless (null v)
        append (list k v)))

(defun present-package (pkg)
  "Return PKG as a plist with :NAME, :VERSION, :LOCATION, and
   :METADATA (nil-valued keys dropped)."
  (clean-for-insert
    (list :name (package-record-name pkg)
          :version (package-record-version pkg)
          :location (package-record-location pkg)
          :metadata (package-record-metadata pkg))))

(defun present-file (file)
  "Return FILE as a plist with :PATH, :SIZE, :CLASS, and :CHECKSUM
   (nil-valued keys dropped)."
  (clean-for-insert
    (list :path (file-path file)
          :size (file-size file)
          :class (file-class file)
          :checksum (file-checksum file))))

(defun add-package-record (store pkg)
  "Add PKG to STORE's package map, keyed by its name."
  (make-store
    :packages (f:with (store-packages store)
                      (package-record-name pkg) pkg)
    :files (store-files store)))

(defun package-with-dependencies (pkg dependencies)
  "Return PKG with its DEPENDENCIES set replaced by DEPENDENCIES."
  (make-package-record
    :name (package-record-name pkg)
    :version (package-record-version pkg)
    :location (package-record-location pkg)
    :metadata (package-record-metadata pkg)
    :is-source (package-record-is-source pkg)
    :dependencies dependencies))

(defun zick-paths (metadata key)
  "Return the paths under METADATA's :ZICK KEY (an FSet seq or nil)."
  (lookup-key (lookup-key metadata :zick) key))

(defun insert-file (store package-id file)
  "Add FILE (a plist with :FILE/PATH, :FILE/SIZE, :FILE/CLASS, and
   :FILE/CHECKSUM) to STORE as owned by PACKAGE-ID."
  (let ((path (getf file :file/path))
        (size (getf file :file/size))
        (class (getf file :file/class))
        (checksum (getf file :file/checksum)))
    (make-store
      :packages (store-packages store)
      :files (f:with (store-files store) path
               (make-file :path path :size size :class class
                          :checksum checksum :owner package-id)))))

(defun insert-use (store depender-id dependee-id)
  "Add DEPENDEE-ID to the dependencies of DEPENDER-ID."
  (let ((pkg (lookup-key (store-packages store) depender-id)))
    (if pkg
        (make-store
          :packages (f:with (store-packages store) depender-id
                      (package-with-dependencies
                        pkg
                        (f:with (package-record-dependencies pkg) dependee-id)))
          :files (store-files store))
        store)))

(defun add-package (store pkg files dependency-ids)
  "Add package PKG and its FILES to STORE.

   PKG is a plist with :PACKAGE-NAME, :PACKAGE-VERSION,
   :PACKAGE-LOCATION, and :PACKAGE-METADATA (an FSet map or nil), plus
   an optional :IS-SOURCE.  FILES is a sequence of plists with :PATH,
   :SIZE, :IS-DIRECTORY, and :CHECKSUM (as produced by unpack);
   entries with :IS-DIRECTORY are skipped.  Paths listed under the
   package's :ZICK :CONFIG-FILES become :CONFIG-FILE records; paths
   under :ZICK :GHOST-FILES become :GHOST-FILE records with size 0.
   DEPENDENCY-IDS is a sequence of package names."
  (let* ((name (getf pkg :package-name))
         (metadata (getf pkg :package-metadata))
         (config-files
           (f:convert 'fset:set (zick-paths metadata :config-files)))
         (ghost-files (zick-paths metadata :ghost-files))
         (pkg-record
           (make-package-record
             :name name
             :version (getf pkg :package-version)
             :location (getf pkg :package-location)
             :metadata metadata
             :is-source (getf pkg :is-source)
             ;; The caller hands us a plain sequence of dependency ids;
             ;; the record invariant is a set of names, so convert at
             ;; this input boundary.
             :dependencies (f:convert 'fset:set dependency-ids)))
         (store (add-package-record store pkg-record)))
    (let ((store (f:reduce
                   (lambda (acc file)
                     (if (getf file :is-directory)
                         acc
                         (insert-file
                           acc name
                           (list :file/path (getf file :path)
                                 :file/size (getf file :size)
                                 :file/class
                                 (if (f:contains? config-files
                                                  (getf file :path))
                                     :config-file
                                     :normal-file)
                                 :file/checksum (getf file :checksum)))))
                   files
                   :initial-value store)))
      (f:reduce
        (lambda (acc path)
          (insert-file acc name
                       (list :file/path path :file/size 0
                             :file/class :ghost-file
                             :file/checksum nil)))
        ghost-files
        :initial-value store))))

(defun remove-package (store pkg-id)
  "Remove package PKG-ID, its files, and every reference to it."
  (let* ((packages (store-packages store))
         (packages (f:reduce
                     (lambda (acc name pkg)
                       (cond
                         ((string= name pkg-id)
                          acc)
                         ((f:contains? (package-record-dependencies pkg)
                                       pkg-id)
                          (f:with acc name
                            (package-with-dependencies
                              pkg
                              (f:set-difference
                                (package-record-dependencies pkg)
                                (f:set pkg-id)))))
                         (t
                          (f:with acc name pkg))))
                     packages
                     :initial-value (f:empty-map)))
         (files (f:reduce
                  (lambda (acc path file)
                    (if (string= (file-owner file) pkg-id)
                        acc
                        (f:with acc path file)))
                  (store-files store)
                  :initial-value (f:empty-map))))
    (make-store :packages packages :files files)))

(defun remove-files (store pkg-id)
  "Remove the files owned by package PKG-ID."
  (make-store
    :packages (store-packages store)
    :files (f:reduce
             (lambda (acc path file)
               (if (string= (file-owner file) pkg-id)
                   acc
                   (f:with acc path file)))
             (store-files store)
             :initial-value (f:empty-map))))

(defun remove-uses (store pkg-id)
  "Remove the dependencies of package PKG-ID."
  (let ((pkg (lookup-key (store-packages store) pkg-id)))
    (if pkg
        (make-store
          :packages (f:with (store-packages store) pkg-id
                      (package-with-dependencies pkg (f:empty-set)))
          :files (store-files store))
        store)))

;;; Helpers

(defun file-class-p (thing)
  "Return non-nil if THING is one of the file classes zick records."
  (member thing '(:normal-file :config-file :ghost-file)))
