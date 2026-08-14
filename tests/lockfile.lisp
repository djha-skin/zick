;;;; tests/lockfile.lisp
;;;;
;;;; Unit tests for the declarative zick.lock.nrdl format.

(defpackage #:com.djhaskin.zick/tests/lockfile
  (:use #:cl)
  (:import-from #:com.djhaskin.zick/lockfile
    #:make-lockfile-package
    #:lockfile-package-name
    #:lockfile-package-dependencies
    #:read-lockfile
    #:write-lockfile)
  (:import-from #:fset)
  (:import-from #:parachute
    #:define-test
    #:is
    #:true))

(in-package #:com.djhaskin.zick/tests/lockfile)

(defun temporary-lockfile ()
  (merge-pathnames
   (format nil "zick-lockfile-~d.nrdl" (random 1000000))
   (uiop:temporary-directory)))

(define-test lockfile-round-trips-and-sorts
  :parent nil
  "Lockfile records round-trip through NRDL and are emitted by name."
  (let ((path (temporary-lockfile)))
    (unwind-protect
        (progn
          (write-lockfile
           path
           (list
            (make-lockfile-package
             :name "z"
             :version "1.0"
             :location "https://example/z.zip")
            (make-lockfile-package
             :name "a"
             :version "2.0"
             :location "https://example/a.zip"
             :dependencies (fset:convert 'fset:seq (list "z")))))
          (let ((packages (read-lockfile path)))
            (is string= "a" (lockfile-package-name (first packages)))
            (is string= "z" (lockfile-package-name (second packages)))
            (is equal '("z")
                (fset:convert 'list
                               (lockfile-package-dependencies
                                (first packages))))))
      (uiop:delete-file-if-exists path))))

(define-test lockfile-rejects-unsupported-version
  :parent nil
  "Lockfiles with an unknown format version fail clearly."
  (let ((path (temporary-lockfile)))
    (unwind-protect
        (progn
          (with-open-file (stream path :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create)
            (write-string "{version 99 packages []}" stream))
          (let ((message
                  (handler-case (progn (read-lockfile path) nil)
                    (error (condition) (princ-to-string condition)))))
            (true (search "unsupported" (string-downcase message)))))
      (uiop:delete-file-if-exists path))))

(define-test lockfile-rejects-duplicate-names
  :parent nil
  "Duplicate package names are rejected while reading a lockfile."
  (let ((path (temporary-lockfile)))
    (unwind-protect
        (progn
          (with-open-file (stream path :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create)
            (write-string
             "{version 1 packages [{name \"a\" version \"1\" location \"x\"} {name \"a\" version \"2\" location \"y\"}]}"
             stream))
          (let ((message
                  (handler-case (progn (read-lockfile path) nil)
                    (error (condition) (princ-to-string condition)))))
            (true (search "duplicate" (string-downcase message)))))
      (uiop:delete-file-if-exists path))))
