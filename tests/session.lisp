;;;; tests/session.lisp
;;;;
;;;; Unit tests for the ported session layer in src/session.lisp,
;;;; mirroring zic's test/zic/session_test.clj and covering the
;;;; lock-file semantics of with-filelock.

(defpackage #:com.djhaskin.zick/tests/session
  (:use #:cl)
  (:import-from #:com.djhaskin.zick/db)
  (:import-from #:com.djhaskin.zick/session)
  (:import-from #:uiop)
  (:import-from #:parachute
    #:define-test
    #:is
    #:true
    #:fail)
  (:local-nicknames
    (#:db #:com.djhaskin.zick/db)
    (#:session #:com.djhaskin.zick/session)))

(in-package #:com.djhaskin.zick/tests/session)

;;; Test helpers

(defun lock-path ()
  "A fresh lock file path under the temporary directory."
  (merge-pathnames
    (format nil "zick-lock-test-~d.lock" (random 1000000))
    (uiop:temporary-directory)))

(defun db-directory ()
  "A fresh .zick-db-style directory under the temporary directory."
  (uiop:ensure-directory-pathname
    (merge-pathnames
      (format nil "zick-db-test-~d/" (random 1000000))
      (uiop:temporary-directory))))

(defun add-sample-package (store)
  "Add a package named a to STORE, returning the new store."
  (db:add-package store
                  (list :package-name "a"
                        :package-version "0.1.0"
                        :package-location "loc"
                        :package-metadata nil)
                  nil
                  nil))

;;; path-to-connection-string

(define-test path-to-connection-string-absolutizes
  :parent nil
  "path-to-connection-string returns an absolute path string, even
   for a relative input (mirrors zic's session test)."
  (let ((cs (session:path-to-connection-string "rel/dir")))
    (is string= "rel/dir"
        (subseq cs (- (length cs) (length "rel/dir"))))
    (true (uiop:absolute-pathname-p (pathname cs))))
  (let ((cs (session:path-to-connection-string "")))
    (true (uiop:absolute-pathname-p (pathname cs))))
  (let ((cs (session:path-to-connection-string "/tmp/zick-dir")))
    (is string= "/tmp/zick-dir" cs)))

;;; with-filelock

(define-test with-filelock-runs-and-cleans-up
  :parent nil
  "with-filelock runs the thunk and removes the lock file on close."
  (let* ((lock (lock-path))
         (ran nil))
    (unwind-protect
        (progn
          (session:with-filelock lock (lambda () (setf ran t)))
          (is eq t ran)
          (true (null (probe-file lock))))
      (uiop:delete-file-if-exists lock))))

(define-test with-filelock-signals-when-held
  :parent nil
  "with-filelock signals a descriptive error when the lock is held,
   and leaves the lock file in place."
  (let ((lock (lock-path)))
    (unwind-protect
        (progn
          ;; Simulate another zick process holding the lock.
          (with-open-file (stream lock :direction :output
                                  :if-exists nil
                                  :if-does-not-exist
                                  :create)
            (true (not (null stream))))
          (handler-case
              (session:with-filelock
                lock
                (lambda () (fail "unreachable")))
            (error (e)
              (true (search "Could not acquire file lock"
                            (princ-to-string e)))
              (true (search "zick process is running"
                            (princ-to-string e)))))
          (true (uiop:file-exists-p lock)))
      (uiop:delete-file-if-exists lock))))

(define-test with-filelock-reacquires-after-release
  :parent nil
  "with-filelock can be reacquired once the previous lock is gone."
  (let ((lock (lock-path)))
    (unwind-protect
        (progn
          (session:with-filelock lock (lambda () nil))
          (session:with-filelock lock (lambda () nil)))
      (uiop:delete-file-if-exists lock))))

(define-test lock-held-by-another-process
  :parent nil
  "A lock held by a separate process blocks with-filelock, and is
   acquirable once that process releases it."
  (let* ((lock (lock-path))
         (lock-name (uiop:native-namestring lock))
         (cmd (format nil "touch ~a; sleep 2; rm -f ~a"
                      lock-name lock-name)))
    (unwind-protect
        (let ((proc (uiop:launch-program (list "sh" "-c" cmd)
                                         :wait nil)))
          (unwind-protect
              (progn
                ;; Wait for the child to create the lock file.
                (loop repeat 100
                      while (null (probe-file lock))
                      do (sleep 0.05))
                (true (probe-file lock))
                (handler-case
                    (session:with-filelock
                      lock
                      (lambda () (fail "unreachable")))
                  (error (e)
                    (true (search "Could not acquire file lock"
                                  (princ-to-string e)))
                    (true (search "zick process is running"
                                  (princ-to-string e)))))
                ;; Wait for the child to release the lock.
                (uiop:wait-process proc)
                (true (null (probe-file lock)))
                (session:with-filelock lock (lambda () nil))
                (true (null (probe-file lock))))
            (uiop:wait-process proc)))
      (uiop:delete-file-if-exists lock))))

;;; with-database

(define-test with-database-creates-store-file
  :parent nil
  "with-database lazily creates the NRDL store file (datalevin's
   create-on-open), even when the thunk returns nothing."
  (let* ((dir (db-directory))
         (conn (uiop:native-namestring dir)))
    (unwind-protect
        (progn
          (session:with-database conn (lambda (store) store))
          (true (uiop:file-exists-p
                  (merge-pathnames "packages.nrdl" dir))))
      (uiop:delete-directory-tree dir :validate t))))

(define-test with-database-persists-mutations
  :parent nil
  "with-database saves the store the thunk returns, so a later
   session sees the mutation."
  (let* ((dir (db-directory))
         (conn (uiop:native-namestring dir)))
    (unwind-protect
        (progn
          (session:with-database conn #'add-sample-package)
          (session:with-database conn
                                 (lambda (store)
                                   (is string= "a"
                                       (getf (db:package-info
                                               store "a")
                                             :name)))))
      (uiop:delete-directory-tree dir :validate t))))

(define-test with-database-does-not-save-on-signal
  :parent nil
  "with-database does not save the store when the thunk signals."
  (let* ((dir (db-directory))
         (conn (uiop:native-namestring dir)))
    (unwind-protect
        (progn
          (handler-case
              (session:with-database conn
                                     (lambda (store)
                                       (declare (ignore store))
                                       (error "boom")))
            (error (e)
              (is string= "boom" (princ-to-string e))))
          ;; No store file was written.
          (true (null (uiop:file-exists-p
                        (merge-pathnames "packages.nrdl" dir)))))
      (uiop:delete-directory-tree dir :validate t
                                  :if-does-not-exist :ignore))))

;;; with-zic-session

(define-test with-zic-session-locks-and-persists
  :parent nil
  "with-zic-session takes the lock first, opens the database, and
   leaves no lock file behind."
  (let* ((root (uiop:ensure-directory-pathname
                 (merge-pathnames
                   (format nil "zick-root-test-~d/"
                           (random 1000000))
                   (uiop:temporary-directory))))
         (db-dir (merge-pathnames "zick-db/" root))
         (conn (uiop:native-namestring db-dir))
         (lock (merge-pathnames "zick.lock" root)))
    (unwind-protect
        (progn
          (ensure-directories-exist db-dir)
          (session:with-zic-session conn lock #'add-sample-package)
          (true (null (probe-file lock)))
          (session:with-zic-session conn lock
                                    (lambda (store)
                                      (is string= "a"
                                          (getf (db:package-info
                                                  store "a")
                                                :name)))))
      (uiop:delete-directory-tree root :validate t))))

;;; More lock and store-file details

(define-test with-filelock-removes-lock-on-signal
  :parent nil
  "with-filelock removes the lock file even when the thunk signals."
  (let ((lock (lock-path)))
    (unwind-protect
        (progn
          (handler-case
              (session:with-filelock
                lock
                (lambda () (error "boom")))
            (error (e)
              (is string= "boom" (princ-to-string e))))
          (true (null (probe-file lock))))
      (uiop:delete-file-if-exists lock))))

(define-test with-zic-session-releases-lock-on-signal
  :parent nil
  "with-zic-session releases the lock when the thunk signals."
  (let* ((root (uiop:ensure-directory-pathname
                 (merge-pathnames
                   (format nil "zick-root-err-~d/"
                           (random 1000000))
                   (uiop:temporary-directory))))
         (db-dir (merge-pathnames "zick-db/" root))
         (conn (uiop:native-namestring db-dir))
         (lock (merge-pathnames "zick.lock" root)))
    (unwind-protect
        (progn
          (ensure-directories-exist db-dir)
          (handler-case
              (session:with-zic-session conn lock
                                        (lambda (store)
                                          (declare (ignore store))
                                          (error "boom")))
            (error (e)
              (is string= "boom" (princ-to-string e))))
          (true (null (probe-file lock))))
      (uiop:delete-directory-tree root :validate t))))

(define-test store-file-path-joins-connection
  :parent nil
  "store-file-path places packages.nrdl inside the connection
   directory, with or without a trailing slash."
  (let ((path (session::store-file-path "/tmp/zick-db")))
    (is string= "packages.nrdl" (file-namestring path))
    (is string= "/tmp/zick-db/"
        (uiop:native-namestring
          (uiop:pathname-directory-pathname path))))
  (let ((path (session::store-file-path "/tmp/zick-db/")))
    (is string= "packages.nrdl" (file-namestring path))))
