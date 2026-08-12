;;;; tests/db.lisp
;;;;
;;;; Unit tests for the ported package/file store in src/db.lisp,
;;;; mirroring zic's test/zic/db_test.clj.

(defpackage #:com.djhaskin.zick/tests/db
  (:use #:cl)
  (:import-from #:fset)
  (:import-from #:uiop)
  (:import-from #:parachute
    #:define-test
    #:is
    #:true)
  (:local-nicknames
    (#:db #:com.djhaskin.zick/db)
    (#:f #:fset)))

(in-package #:com.djhaskin.zick/tests/db)

;;; Test helpers

(defun config-metadata ()
  "A metadata map declaring c/echo.txt a config file and c/ghost.txt
   a ghost file."
  (f:map (:zic
           (f:map (:config-files
                    (f:convert 'fset:seq '("c/echo.txt")))
                  (:ghost-files
                    (f:convert 'fset:seq '("c/ghost.txt")))))))

(defun sample-store ()
  "A store with packages a, b, and c.  c depends on a, and b depends
   on a and c.  c owns three files (one a config file, one a ghost
   file, one a directory entry that gets skipped)."
  (let ((store (db:empty-store)))
    (setf store
          (db:add-package store
                          (list :package-name "a"
                                :package-version "0.1.0"
                                :package-location
                                "https://djhaskin987.me:8443/a.zip"
                                :package-metadata (f:map (:mood :rare)))
                          nil
                          nil))
    (setf store
          (db:add-package store
                          (list :package-name "c"
                                :package-version "0.1.0"
                                :package-location
                                "https://djhaskin987.me:8443/c.zip"
                                :package-metadata (config-metadata))
                          (list (list :path "c/echo.txt" :size 13
                                      :is-directory nil :checksum "abc")
                                (list :path "c/real.txt" :size 5
                                      :is-directory nil :checksum "def")
                                (list :path "c/dir/" :size 0
                                      :is-directory t :checksum nil))
                          '("a")))
    (setf store
          (db:add-package store
                          (list :package-name "b"
                                :package-version "0.2.0"
                                :package-location
                                "https://djhaskin987.me:8443/b.zip"
                                :package-metadata (f:empty-map))
                          nil
                          '("a" "c")))))

(defun find-by-path (path plists)
  "Find the plist in PLISTS whose :PATH is PATH."
  (find path plists :key (lambda (p) (getf p :path)) :test #'string=))

;;; Store basics

(define-test empty-store
  :parent nil
  "empty-store has no packages or files."
  (let ((store (db:empty-store)))
    (is = 0 (f:size (db:store-packages store)))
    (is = 0 (f:size (db:store-files store)))))

(define-test init-database-is-noop
  :parent nil
  "init-database initializes nothing (stores are created lazily)."
  (true (null (db:init-database "/tmp/whatever"))))

(define-test package-id-finds-and-misses
  :parent nil
  "package-id returns the id (name) of an installed package, or nil."
  (let ((store (sample-store)))
    (is string= "a" (db:package-id store "a"))
    (true (null (db:package-id store "not-exist")))))

(define-test package-info-presents-package
  :parent nil
  "package-info returns the presented plist of an installed package."
  (let ((info (db:package-info (sample-store) "a")))
    (is string= "a" (getf info :name))
    (is string= "0.1.0" (getf info :version))
    (is string= "https://djhaskin987.me:8443/a.zip" (getf info :location))
    (is equal :rare (f:lookup (getf info :metadata) :mood))))

(define-test package-info-misses-and-by-id
  :parent nil
  "package-info and package-info-by-id return nil for unknown ids."
  (let ((store (sample-store)))
    (true (null (db:package-info store "not-exist")))
    (true (null (db:package-info-by-id store nil)))
    (true (null (db:package-info-by-id store "no-such")))
    (is string= "b"
        (getf (db:package-info-by-id store "b") :name))))

;;; Files

(define-test package-files-classify
  :parent nil
  "package-files presents a package's files, classifying config and
   ghost files and skipping directory entries."
  (let* ((store (sample-store))
         (files (db:package-files store "c"))
         (echo (find-by-path "c/echo.txt" files))
         (real (find-by-path "c/real.txt" files))
         (ghost (find-by-path "c/ghost.txt" files)))
    (true (not (null echo)))
    (is eq :config-file (getf echo :class))
    (is = 13 (getf echo :size))
    (is string= "abc" (getf echo :checksum))
    (true (not (null real)))
    (is eq :normal-file (getf real :class))
    (is = 5 (getf real :size))
    (true (not (null ghost)))
    (is eq :ghost-file (getf ghost :class))
    (is = 0 (getf ghost :size))
    (true (null (getf ghost :checksum)))
    (true (null (find-by-path "c/dir/" files)))))

(define-test owned-by-p
  :parent nil
  "owned-by-p names the package that owns a file, or nil."
  (let ((store (sample-store)))
    (is string= "c" (db:owned-by-p store "c/echo.txt"))
    (true (null (db:owned-by-p store "no/such")))))

(define-test insert-file
  :parent nil
  "insert-file adds an owned file to the store."
  (let* ((store (db:add-package (db:empty-store)
                                (list :package-name "a"
                                      :package-version "0.1.0"
                                      :package-location "loc"
                                      :package-metadata nil)
                                nil
                                nil))
         (store (db:insert-file store "a"
                                (list :file/path "a/f.txt" :file/size 3
                                      :file/class :normal-file
                                      :file/checksum "cafe"))))
    (is string= "a" (db:owned-by-p store "a/f.txt"))
    (is = 3 (getf (first (db:package-files store "a")) :size))))

;;; Dependencies

(define-test insert-use
  :parent nil
  "insert-use adds a dependency between two packages."
  (let* ((store (db:add-package (db:empty-store)
                                (list :package-name "a"
                                      :package-version "0.1.0"
                                      :package-location "loc"
                                      :package-metadata nil)
                                nil
                                nil))
         (store (db:add-package store
                                (list :package-name "b"
                                      :package-version "0.1.0"
                                      :package-location "loc"
                                      :package-metadata nil)
                                nil
                                nil))
         (store (db:insert-use store "a" "b")))
    (is string= "b"
        (getf (first (db:package-dependees store "a")) :name))))

(define-test dependers
  :parent nil
  "dependers-by-id and package-dependers list the packages depending
   on a given one."
  (let* ((store (sample-store))
         (deps (db:dependers-by-id store "a")))
    (is = 2 (length deps))
    (true (member "b" deps :test #'string=))
    (true (member "c" deps :test #'string=))
    (is = 1 (length (db:dependers-by-id store "c")))
    (is = 0 (length (db:dependers-by-id store "b")))
    (let ((dependers (db:package-dependers store "a")))
      (is = 2 (length dependers))
      (true (some (lambda (p) (string= "b" (getf p :name))) dependers)))
    (true (null (db:package-dependers store "not-exist")))))

(define-test dependees
  :parent nil
  "package-dependees lists the packages a package depends on."
  (let* ((store (sample-store))
         (dependees (db:package-dependees store "b")))
    (is = 2 (length dependees))
    (true (some (lambda (p) (string= "a" (getf p :name))) dependees))
    (true (some (lambda (p) (string= "c" (getf p :name))) dependees))
    (true (null (db:package-dependees store "not-exist")))))

;;; Removal

(define-test remove-files-and-uses
  :parent nil
  "remove-files deletes a package's files and remove-uses clears its
   dependencies."
  (let* ((store (sample-store))
         (store (db:remove-files store "c"))
         (store (db:remove-uses store "b")))
    (is = 0 (length (db:package-files store "c")))
    (is = 0 (length (db:package-dependees store "b")))
    (is = 0 (length (db:dependers-by-id store "b")))))

(define-test remove-package
  :parent nil
  "remove-package removes a package and its files, and strips it from
   other packages' dependencies."
  (let* ((store (sample-store))
         (store (db:remove-package store "c")))
    (true (null (db:package-id store "c")))
    (is = 0 (length (db:package-files store "c")))
    (true (null (db:owned-by-p store "c/echo.txt")))
    ;; b no longer depends on c, but still depends on a
    (is = 1 (length (db:package-dependees store "b")))
    (is string= "a"
        (getf (first (db:package-dependees store "b")) :name))))

(define-test remove-package-strips-references
  :parent nil
  "remove-package strips the removed package from other packages'
   dependencies."
  (let* ((store (db:add-package (db:empty-store)
                                (list :package-name "a"
                                      :package-version "0.1.0"
                                      :package-location "loc"
                                      :package-metadata nil)
                                nil
                                '("b")))
         (store (db:add-package store
                                (list :package-name "b"
                                      :package-version "0.1.0"
                                      :package-location "loc"
                                      :package-metadata nil)
                                nil
                                nil))
         (store (db:remove-package store "b")))
    (true (null (db:package-id store "b")))
    (is = 0 (length (db:package-dependees store "a")))))

;;; Identity and helpers

(define-test add-package-overwrites-by-name
  :parent nil
  "Adding a package with an existing name replaces the record."
  (let* ((store (db:add-package (db:empty-store)
                                (list :package-name "a"
                                      :package-version "1.0.0"
                                      :package-location "old"
                                      :package-metadata nil)
                                nil
                                nil))
         (store (db:add-package store
                                (list :package-name "a"
                                      :package-version "2.0.0"
                                      :package-location "new"
                                      :package-metadata nil)
                                nil
                                nil)))
    (is string= "2.0.0" (getf (db:package-info store "a") :version))
    (is string= "new" (getf (db:package-info store "a") :location))))

(define-test clean-for-insert
  :parent nil
  "clean-for-insert drops nil-valued pairs."
  (is equal '(:a 1 :c 3)
      (db:clean-for-insert (list :a 1 :b nil :c 3))))

(define-test file-class-p-checks
  :parent nil
  "file-class-p recognizes the recorded file classes."
  (true (db:file-class-p :normal-file))
  (true (db:file-class-p :config-file))
  (true (db:file-class-p :ghost-file))
  (true (null (db:file-class-p :directory))))

;;; Persistence

(define-test store-round-trips
  :parent nil
  "save-store writes an NRDL file that slurp-store reads back."
  (let* ((store (sample-store))
         (path (merge-pathnames
                 (format nil "zick-db-test-~a.nrdl" (random 1000000))
                 (uiop:temporary-directory))))
    (unwind-protect
        (progn
          (db:save-store path store)
          (let ((loaded (db:slurp-store path)))
            (is string= "c" (db:owned-by-p loaded "c/echo.txt"))
            (is string= "0.2.0"
                (getf (db:package-info loaded "b") :version))
            (is = 2 (length (db:package-dependees loaded "b")))
            (is = 3 (length (db:package-files loaded "c")))))
      (uiop:delete-file-if-exists path))))

(define-test slurp-missing-store
  :parent nil
  "slurp-store returns an empty store when the file is missing."
  (let ((store (db:slurp-store
                 (merge-pathnames "no-such-store.nrdl"
                                  (uiop:temporary-directory)))))
    (is = 0 (f:size (db:store-packages store)))
    (is = 0 (f:size (db:store-files store)))))
