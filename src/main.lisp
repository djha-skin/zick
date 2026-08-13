;;;; src/main.lisp
;;;;
;;;; CLI entry point for zick using CLIFF for argument parsing,
;;;; subcommand dispatch, config files, and environment variables.
;;;;
;;;; Ported from zic's src/zic/cli.clj.  Subcommand functions take the
;;;; CLIFF options hash (converted to a plist), call into the package
;;;; layer, and return a hash table of results which CLIFF prints as an
;;;; NRDL document.  The setup function locates the `.zick-db` marking
;;;; file (falling back to the deprecated `.zic-db` with a warning) and
;;;; derives the database connection string, project root, staging, and
;;;; lock paths, mirroring zic's onecli setup.

(defpackage #:com.djhaskin.zick
  (:use #:cl)
  (:import-from #:com.djhaskin.cliff
    #:execute-program)
  (:import-from #:com.djhaskin.cliff/errors
    #:*exit-codes*)
  (:import-from #:com.djhaskin.zick/db
    #:init-database)
  (:import-from #:com.djhaskin.zick/fs
    #:find-marking-file)
  (:import-from #:com.djhaskin.zick/session
    #:path-to-connection-string
    #:with-database)
  (:import-from #:com.djhaskin.zick/package
    #:get-package-dependees
    #:get-package-dependers
    #:get-package-files
    #:get-package-info
    #:install-package
    #:remove-package
    #:verify-package-files)
  (:import-from #:com.djhaskin.nrdl
    #:parse-from
    #:to-fset)
  (:import-from #:uiop)
  (:import-from #:fset)
  (:import-from #:gmap)
  (:import-from #:alexandria)
  (:import-from #:asdf
    #:component-version
    #:find-system)
  (:local-nicknames
    (#:cliff #:com.djhaskin.cliff)
    (#:db #:com.djhaskin.zick/db)
    (#:fs #:com.djhaskin.zick/fs)
    (#:session #:com.djhaskin.zick/session)
    (#:pkg #:com.djhaskin.zick/package)
    (#:nrdl #:com.djhaskin.nrdl)
    (#:f #:fset))
  (:export
    #:main))

(in-package #:com.djhaskin.zick)

;;; zic exits 3 when verify finds no such package and 4 when it finds
;;; verification failures; CLIFF's stock exit codes lack these, so
;;; extend its table at load time.
(eval-when (:load-toplevel)
  (setf (gethash :package-not-found *exit-codes*) 3)
  (setf (gethash :verification-failed *exit-codes*) 4))

(defparameter *zick-version*
  (component-version (find-system :com.djhaskin.zick))
  "Version of the zick system, read from its ASDF definition.

   Shown on the CLIFF-generated help page.")

;;; Helpers

(defparameter *package-name-required*
  "Package name (`package-name`) option needs to be specified."
  "The error message for subcommands missing their required
   package-name option.")

(defun exit-with (status-code msg)
  "Print MSG to stderr and return a CLIFF result map exiting with
   STATUS-CODE (a key of CLIFF's *exit-codes*)."
  (format *error-output* "~a~%" msg)
  (alexandria:alist-hash-table
    `((:status . ,status-code)
      (:cliff-suppress-output . t))))

(defun hash-to-plist (options)
  "Convert the CLIFF options hash table to a plist for the package
   layer."
  (loop for key being the hash-keys of options
        append (list key (gethash key options))))

(defun plist-to-hash (plist)
  "Convert PLIST to a hash table for NRDL serialization."
  (alexandria:alist-hash-table
    (loop for (k v) on plist by #'cddr
          collect (cons k v))
    :test 'equal))

(defun verification-to-data (results)
  "Convert the verification alist (RESULT-KEY . INFOS) to a hash table
   mapping each RESULT-KEY to an array of file hash tables."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (result . infos) in results
          do (setf (gethash result ht)
                   (mapcar #'plist-to-hash infos)))
    ht))

(defun keywordize-fset-map (fmap)
  "Return FMAP with string and symbol keys interned as keywords,
   recursing into values.

   NRDL reads JSON string keys back as lowercase keywords (e.g.
   :|zick|), so both strings and symbols are normalized to the
   keyword spelling the store looks up (:ZICK)."
  (let ((result (f:empty-map)))
    (fset:do-map (k v fmap)
                 (setf result (f:with result
                                      (cond
                                        ((stringp k)
                                         (intern (string-upcase k) :keyword))
                                        ((symbolp k)
                                         (intern (string-upcase
                                                   (symbol-name k))
                                                 :keyword))
                                        (t k))
                                (keywordize-fset-value v))))
    result))

(defun keywordize-fset-value (value)
  "Recursively convert the string keys of VALUE (an fset map or seq)
   to keywords, matching the store's keyword-keyed metadata maps."
  (etypecase value
    (f:map (keywordize-fset-map value))
    (f:seq (keywordize-fset-seq value))
    (t value)))

(defun keywordize-fset-seq (seq)
  "Return SEQ with each element's string keys converted to keywords."
  (f:convert 'fset:seq
             (gmap:gmap (:result list) #'keywordize-fset-value
                                       (:arg :seq seq))))

(defun json-metadata-to-fset (json-string)
  "Parse the JSON string into an fset map with keyword keys.

   NRDL is a JSON superset, so parse-from reads JSON directly; the
   string keys it produces are keywordized to match zick's metadata
   key convention."
  (keywordize-fset-value
    (nrdl:to-fset (nrdl:parse-from
                    (make-string-input-stream json-string)))))

(defun keywordize-auth-record (record)
  "Return RECORD (a string-keyed hash table from NRDL) as a hash
   table keyed by keywords, with :TYPE left as its string value and
   :HEADERS as an alist, matching fs:download's authorization record
   contract."
  (let ((result (make-hash-table :test 'equal)))
    (maphash
      (lambda (k v)
        (let ((key (intern (string-upcase k) :keyword)))
          (setf (gethash key result)
                (if (and (eql key :headers)
                         (hash-table-p v))
                    (loop for hk being the hash-keys of v
                          using (hash-value hv)
                          collect (cons hk hv))
                    v))))
      record)
    result))

(defun json-download-authorizations-to-table (json-string)
  "Parse the JSON download-authorizations string into a hash table
   keyed by host keyword, each value an authorization record hash
   table, matching fs:download's contract.

   The JSON is the per-host map zic's problems.md describes, e.g.
   {\"djhaskin987.me\": {\"type\": \"basic\", \"username\": \"mode\",
   \"password\": \"code\"}}."
  (let ((parsed (nrdl:parse-from
                  (make-string-input-stream json-string)))
        (result (make-hash-table :test 'equal)))
    (maphash
      (lambda (host record)
        (setf (gethash (intern (string-upcase host) :keyword) result)
              (keywordize-auth-record record)))
      parsed)
    result))

(defun find-marking-file-compat (start)
  "Find the zick marking file at or above START, preferring `.zick-db`
   and falling back to the deprecated `.zic-db` (with a warning)."
  (or (find-marking-file start ".zick-db")
      (let ((legacy (find-marking-file start ".zic-db")))
        (when legacy
          (format *error-output*
                  "Warning: `.zic-db` is deprecated; use `.zick-db`.~%"))
        legacy)))

;;; Subcommands

(defun add-command (options)
  "Install the package described by the options."
  (let ((opts (hash-to-plist options)))
    (pkg:install-package opts)
    (alexandria:alist-hash-table
      `((:status . :successful)
        (:result . :successful)))))

(defun files-command (options)
  "List the files owned by a package."
  (when (null (gethash :package-name options))
    (return-from files-command
                 (exit-with :cl-usage-error *package-name-required*)))
  (let* ((opts (hash-to-plist options))
         (files (pkg:get-package-files opts)))
    (if (null files)
        (alexandria:alist-hash-table
          `((:status . :successful)
            (:result . :not-found)))
        (alexandria:alist-hash-table
          `((:status . :successful)
            (:result . :package-found)
            (:package-files . ,(mapcar #'plist-to-hash files)))))))

(defun info-command (options)
  "Show information about a package."
  (when (null (gethash :package-name options))
    (return-from info-command
                 (exit-with :cl-usage-error *package-name-required*)))
  (let* ((opts (hash-to-plist options))
         (info (pkg:get-package-info opts)))
    (if (null info)
        (alexandria:alist-hash-table
          `((:status . :successful)
            (:result . :not-found)))
        (alexandria:alist-hash-table
          `((:status . :successful)
            (:result . :package-found)
            (:package-information . ,(plist-to-hash info)))))))

(defun dependers-command (options)
  "List the packages that depend on a package."
  (when (null (gethash :package-name options))
    (return-from dependers-command
                 (exit-with :cl-usage-error *package-name-required*)))
  (let* ((opts (hash-to-plist options))
         (dependers (pkg:get-package-dependers opts)))
    (if (null dependers)
        (alexandria:alist-hash-table
          `((:status . :successful)
            (:result . :not-found)))
        (alexandria:alist-hash-table
          `((:status . :successful)
            (:result . :package-found)
            (:package-dependers . ,(mapcar #'plist-to-hash dependers)))))))

(defun dependees-command (options)
  "List the packages a package depends on."
  (when (null (gethash :package-name options))
    (return-from dependees-command
                 (exit-with :cl-usage-error *package-name-required*)))
  (let* ((opts (hash-to-plist options))
         (dependees (pkg:get-package-dependees opts)))
    (if (null dependees)
        (alexandria:alist-hash-table
          `((:status . :successful)
            (:result . :not-found)))
        (alexandria:alist-hash-table
          `((:status . :successful)
            (:result . :package-found)
            (:package-dependees . ,(mapcar #'plist-to-hash dependees)))))))

(defun verify-command (options)
  "Verify the files of a package on disk.

   Exits 3 when the package is not installed and 4 when verification
   finds failures, mirroring zic."
  (when (null (gethash :package-name options))
    (return-from verify-command
                 (exit-with :cl-usage-error *package-name-required*)))
  (let* ((opts (hash-to-plist options))
         (info (pkg:get-package-info opts)))
    (if (null info)
        (alexandria:alist-hash-table
          `((:status . :package-not-found)
            (:result . :package-not-found)))
        (let ((results (pkg:verify-package-files opts)))
          (if (null results)
              (alexandria:alist-hash-table
                `((:status . :successful)
                  (:result . :package-found)
                  (:verification-results . ,(f:empty-seq))))
              (alexandria:alist-hash-table
                (list (cons :status :verification-failed)
                      (cons :result :package-found)
                      (cons :verification-results
                            (verification-to-data results)))))))))
(defun remove-command (options)
  "Remove a package from the installation."
  (when (null (gethash :package-name options))
    (return-from remove-command
                 (exit-with :cl-usage-error *package-name-required*)))
  (let* ((opts (hash-to-plist options))
         (removed (pkg:remove-package opts)))
    (if (null removed)
        (alexandria:alist-hash-table
          `((:status . :successful)
            (:result . :not-found)))
        (alexandria:alist-hash-table
          `((:status . :successful)
            (:result . :package-found)
            (:dry-run . ,(getf opts :dry-run))
            (:removed-packages . ,(mapcar #'plist-to-hash removed)))))))

(defun init-command (options)
  "Initialize the database in the start directory.

   The database is created lazily when opened, mirroring zic's
   init."
  (let* ((start-dir (getf (hash-to-plist options) :start-directory))
         (start-path
           (uiop:ensure-directory-pathname
             (uiop:parse-native-namestring start-dir)))
         (conn (session:path-to-connection-string
                 (merge-pathnames ".zick-db/" start-path))))
    (session:with-database conn
                           (lambda (store) (db:init-database conn)))
    (alexandria:alist-hash-table
      `((:status . :successful)
        (:result . :successful)))))

(defun list-command (options)
  "List installed packages.  Not yet implemented (tracked by its own
   bead)."
  (declare (ignore options))
  (alexandria:alist-hash-table
    `((:status . :successful)
      (:result . :noop))))

(defun orphans-command (options)
  "List the orphaned packages: the installed packages that nothing
   depends on (the source nodes of the dependency graph)."
  (let* ((opts (hash-to-plist options))
         (orphans (pkg:get-orphaned-packages opts)))
    (alexandria:alist-hash-table
      `((:status . :successful)
        (:result . :successful)
        (:orphaned-packages . ,(mapcar #'plist-to-hash orphans))))))

;;; Setup

(defun setup (options)
  "Derive the database connection string, project root, staging, and
   lock paths from the marking file at or above :START-DIRECTORY, and
   parse the `-m` metadata JSON.  Returns the augmented options hash."
  (let* ((start-dir (gethash :start-directory options))
         (start-path (when start-dir
                       (uiop:ensure-directory-pathname
                         (uiop:parse-native-namestring start-dir))))
         (marking (when start-path
                    (find-marking-file-compat start-path))))
    (when marking
      (let ((root (uiop:pathname-parent-directory-pathname marking)))
        (setf (gethash :db-connection-string options)
              (session:path-to-connection-string marking))
        (setf (gethash :root-path options) root)
        (setf (gethash :staging-path options)
              (uiop:ensure-directory-pathname
                (merge-pathnames ".staging" root)))
        (setf (gethash :lock-path options)
              (merge-pathnames ".zick.lock" root))))
    (let ((metadata (gethash :package-metadata options)))
      (when (stringp metadata)
        (setf (gethash :package-metadata options)
              (json-metadata-to-fset metadata))))
    (let ((authorizations (gethash :download-authorizations options)))
      (when (stringp authorizations)
        (setf (gethash :download-authorizations options)
              (json-download-authorizations-to-table authorizations))))
    options))

;;; Default function

(defun default-fn (options)
  "Default function when no subcommand is given.

   Prints a brief usage summary naming the subcommands.  Returns a
   successful status."
  (declare (ignore options))
  (format t "zick: Zip files In Concert~%")
  (format t "A package manager for project-level source code repositories.~%")
  (format t "~%")
  (format t "Subcommands:~%")
  (format t "  add         Add a package to the installation~%")
  (format t "  files       List the files owned by a package~%")
  (format t "  info        Show information about a package~%")
  (format t "  init        Initialize the zick database~%")
  (format t "  list        List installed packages~%")
  (format t "  orphans     List orphaned packages (nothing depends on them)~%")
  (format t "  remove      Remove a package from the installation~%")
  (format t "  dependers   List packages that depend on a package~%")
  (format t "  dependees   List packages a package depends on~%")
  (format t "  verify      Verify the files of a package~%")
  (format t "~%")
  (format t "Run `zick help` for the CLIFF help page.~%")
  (alexandria:alist-hash-table
    `((:status . :successful)
      (:cliff-suppress-output . t))))

;;; Entry point

(defun main (&rest argv)
  "Main entry point for the zick CLI tool.

   Uses CLIFF's execute-program for argument parsing, config file
   handling, environment variable processing, and subcommand dispatch.
   Returns the process exit code."
  (declare (ignorable argv))
  (nth-value
    0
    (cliff:execute-program
      "zick"
      :version *zick-version*
      :subcommand-functions
      (list
        (cons '("add") #'add-command)
        (cons '("files") #'files-command)
        (cons '("info") #'info-command)
        (cons '("init") #'init-command)
        (cons '("list") #'list-command)
        (cons '("orphans") #'orphans-command)
        (cons '("remove") #'remove-command)
        (cons '("dependers") #'dependers-command)
        (cons '("dependees") #'dependees-command)
        (cons '("verify") #'verify-command))
      :default-function #'default-fn
      :defaults
      (list (cons :output-format "nrdl")
            (cons :start-directory (uiop:native-namestring (uiop:getcwd)))
            (cons :cascade nil)
            (cons :dry-run nil)
            (cons :download-package t))
      :setup #'setup
      :cli-aliases
      '(;; Global
        ("-d" . "--set-start-directory")
        ;; On add
        ("-k" . "--set-package-name")
        ("-V" . "--set-package-version")
        ("-l" . "--set-package-location")
        ("-m" . "--set-package-metadata")
        ("--json-download-authorizations"
         . "--set-download-authorizations")
        ("-u" . "--add-package-dependency")
        ("-W" . "--disable-download-package")
        ("-w" . "--enable-download-package")
        ("-n" . "--enable-insecure")
        ("-N" . "--disable-insecure")
        ("-G" . "--disable-allow-downgrades")
        ("-g" . "--enable-allow-downgrades")
        ("-I" . "--disable-allow-inplace")
        ("-i" . "--enable-allow-inplace")
        ;; On remove
        ("-c" . "--enable-cascade")
        ("-C" . "--disable-cascade")
        ("-r" . "--enable-dry-run")
        ("-R" . "--disable-dry-run")
        ;; Help
        ("-h" . "help")
        ("--help" . "help"))
      :cli-arguments (if argv (coerce argv 'list) t))))
