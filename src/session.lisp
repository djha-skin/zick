;;;; src/session.lisp
;;;;
;;;; Database sessions and the zick lock file.
;;;;
;;;; Ported from zic's src/zic/session.clj.  zic opened a datalevin
;;;; connection and took a java.nio FileLock with DELETE_ON_CLOSE.
;;;; The port keeps the same structure but, per the decide-db
;;;; decision, the "connection" is the NRDL store slurped by
;;;; db:slurp-store, and the lock is a plain lock file: its very
;;;; existence is the lock, created atomically with open's
;;;; :if-exists nil semantics (O_EXCL) and removed on close.  zick
;;;; only needs to coordinate with other zick processes, so an
;;;; advisory lock file is all that is required.

(defpackage #:com.djhaskin.zick/session
  (:use #:cl)
  (:import-from #:com.djhaskin.zick/db)
  (:import-from #:uiop)
  (:local-nicknames
    (#:db #:com.djhaskin.zick/db))
  (:export
    #:with-filelock
    #:with-database
    #:with-zick-session
    #:path-to-connection-string))

(in-package #:com.djhaskin.zick/session)

;;; The name of the NRDL store document inside the .zick-db
;;; directory.
(defparameter *store-file-name* "packages.nrdl")

(defun path-to-connection-string (path)
  "Return the absolute native namestring of PATH, the connection
   string for the database at that directory."
  (uiop:native-namestring (merge-pathnames (pathname path))))

(defun store-file-path (connection-string)
  "Return the pathname of the NRDL store file for the database whose
   connection string is CONNECTION-STRING (the .zick-db directory)."
  (merge-pathnames
    *store-file-name*
    (uiop:ensure-directory-pathname
      (uiop:parse-native-namestring connection-string))))

(defun with-filelock (path f)
  "Surround the invocation of the function F with an exclusive lock
   on the file at PATH.

   The lock is a lock file: creating it atomically (open with
   :if-exists nil, i.e. O_EXCL) is the acquisition, and deleting it
   is the release.  If another zick process holds the lock, signal
   a descriptive error.  The lock file is removed on close, whether
   F returns normally or signals.

   Because the lock is the file's existence, a zick process that
   dies without running the cleanup (e.g. SIGKILL) leaves a stale
   lock file behind; remove it manually to recover.  zick only
   coordinates with other zick processes, so no OS-level lock is
   needed."
  (let ((stream (open path :direction :output :if-exists nil
                      :if-does-not-exist :create)))
    (if (null stream)
        (error "Could not acquire file lock on `~a`. ~
                Probably another zick process is running."
               path)
        (unwind-protect
            (funcall f)
          (close stream)
          (uiop:delete-file-if-exists path)))))

(defun with-database (connection-string f)
  "Open the database at CONNECTION-STRING, invoke F with the store,
   and save the store F returns (or the opened store, if F returns
   nothing) before returning F's result.

   Opening creates the store file if it is missing, mirroring
   datalevin's lazy creation on open.  If F signals, the store is
   not saved."
  (let* ((store-path (store-file-path connection-string))
         (store (db:slurp-store store-path))
         (result (funcall f store)))
    (db:save-store store-path
                   (if (db:store-p result) result store))
    result))

(defun with-zick-session (connection-string lock-path f)
  "Surround the invocation of F with a zick session: take the lock
   at LOCK-PATH, then open the database at CONNECTION-STRING and
   invoke F with the store.

   The lock is taken before the database is opened so that two
   concurrent zick sessions serialize on the lock before either
   reads the store."
  (with-filelock lock-path
                 (lambda ()
                         (with-database connection-string f))))
