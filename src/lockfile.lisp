;;;; src/lockfile.lisp
;;;;
;;;; The declarative project lockfile.  This is deliberately separate from
;;;; .zick.nrdl, which is CLIFF's project configuration file.

(defpackage #:com.djhaskin.zick/lockfile
  (:use #:cl)
  (:import-from #:com.djhaskin.nrdl)
  (:import-from #:fset)
  (:import-from #:uiop)
  (:local-nicknames
    (#:nrdl #:com.djhaskin.nrdl)
    (#:f #:fset))
  (:export
    #:lockfile-package
    #:make-lockfile-package
    #:lockfile-package-p
    #:lockfile-package-name
    #:lockfile-package-version
    #:lockfile-package-location
    #:lockfile-package-dependencies
    #:lockfile-package-metadata
    #:read-lockfile
    #:write-lockfile))

(in-package #:com.djhaskin.zick/lockfile)

(defstruct lockfile-package
  "One package declaration in a zick.lock.nrdl file."
  name version location
  (dependencies '())
  metadata)

(defun lookup (object key)
  (nth-value 0 (f:lookup object key)))

(defun required-string (object key)
  (let ((value (lookup object key)))
    (unless (stringp value)
      (error "Lockfile package field ~a must be a string, got ~s."
             key value))
    value))

(defun sequence-to-list (value key)
  (handler-case
      (f:convert 'list value)
    (error ()
      (error "Lockfile field ~a must be a sequence, got ~s." key value))))

(defun parse-package (object)
  (let ((dependencies (lookup object :dependencies))
        (metadata (lookup object :metadata)))
    (unless dependencies
      (setf dependencies (f:empty-seq)))
    ;; Metadata is intentionally carried through as an FSet map.  The
    ;; serializer/parser will reject non-object values when the map is
    ;; consumed; nil means that no metadata was declared.
    (make-lockfile-package
      :name (required-string object :name)
      :version (required-string object :version)
      :location (required-string object :location)
      :dependencies (mapcar
                     (lambda (dependency)
                       (unless (stringp dependency)
                         (error "Lockfile dependency must be a string, got ~s."
                                dependency))
                       dependency)
                     (sequence-to-list dependencies :dependencies))
      :metadata metadata)))

(defun read-lockfile (path)
  "Read PATH and return its package declarations in file order.

   The current format is an NRDL object with VERSION 1 and a PACKAGES
   sequence.  Package names must be unique."
  (unless (uiop:file-exists-p path)
    (error "Lockfile does not exist: ~a" path))
  (with-open-file (stream path :direction :input)
    (let* ((document (nrdl:to-fset (nrdl:parse-from stream)))
           (version (lookup document :version))
           (packages (lookup document :packages)))
      (unless (eql version 1)
        (error "Unsupported zick lockfile version ~s; expected 1." version))
      (let ((result (mapcar #'parse-package
                            (sequence-to-list packages :packages))))
        (when (/= (length result)
                  (length (remove-duplicates result
                                             :test #'string=
                                             :key #'lockfile-package-name)))
          (error "Lockfile contains duplicate package names."))
        result))))

(defun package-object (package)
  (let ((object (make-hash-table :test 'equal)))
    (setf (gethash :name object) (lockfile-package-name package))
    (setf (gethash :version object) (lockfile-package-version package))
    (setf (gethash :location object) (lockfile-package-location package))
    (setf (gethash :dependencies object)
          (f:convert 'fset:seq
                     (or (lockfile-package-dependencies package) '())))
    (when (lockfile-package-metadata package)
      (setf (gethash :metadata object)
            (lockfile-package-metadata package)))
    object))

(defun write-lockfile (path packages)
  "Write PACKAGES (a list of LOCKFILE-PACKAGE records) to PATH
   atomically.  The package list is sorted by name to keep generated
   lockfiles stable."
  (let ((document (make-hash-table :test 'equal))
        (ordered (sort (copy-list packages) #'string<
                       :key #'lockfile-package-name)))
    (setf (gethash :version document) 1)
    (setf (gethash :packages document)
          (f:convert 'fset:seq (mapcar #'package-object ordered)))
    (ensure-directories-exist path)
    (let ((tmp (uiop:parse-native-namestring
                 (format nil "~a.~d.tmp" path (random 1000000)))))
      (unwind-protect
          (progn
            (with-open-file (stream tmp :direction :output
                                    :if-exists :supersede
                                    :if-does-not-exist :create)
              (nrdl:generate-to stream document :pretty-indent 2))
            (uiop:rename-file-overwriting-target tmp path))
        (uiop:delete-file-if-exists tmp)))))
