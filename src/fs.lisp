;;;; src/fs.lisp
;;;;
;;;; Filesystem and archive helpers for zick: zip reading, checksums,
;;;; downloads, unpacking, and the .zic-db marking-file search.
;;;;
;;;; Ported from zic's src/zic/fs.clj.

(defpackage #:com.djhaskin.zick/fs
  (:use #:cl)
  (:import-from #:org.shirakumo.zippy)
  (:import-from #:ironclad)
  (:import-from #:dexador)
  (:import-from #:quri)
  (:import-from #:alexandria)
  (:import-from #:uiop)
  (:import-from #:fset)
  (:import-from #:gmap)
  (:local-nicknames
    (#:z #:org.shirakumo.zippy)
    (#:f #:fset))
  (:export
    #:new-unique-path
    #:backup-all
    #:remove-files
    #:stream-sha256
    #:stream-crc
    #:file-sha256
    #:file-size
    #:archive-entry-checksums
    #:archive-contents
    #:download
    #:verify
    #:crc-violations
    #:unpack
    #:list-files
    #:all-parents
    #:find-marking-file))

(in-package #:com.djhaskin.zick/fs)

;;; Internal helpers

(defun bytes->hexstr (octets)
  "Return the lowercase hexadecimal string of OCTETS."
  (string-downcase (format nil "~{~2,'0x~}" (coerce octets 'list))))

(defun directory-entry-p (entry)
  "Return true if ENTRY names a directory (its name ends in a slash)."
  (let ((name (z:file-name entry)))
    (and name (alexandria:ends-with-subseq "/" name))))

(defun in-set (set item)
  "Return non-nil if ITEM is in SET.

   SET may be a function, a hash table, or an fset set."
  (etypecase set
    (function (funcall set item))
    (hash-table (not (null (gethash item set))))
    (null nil)
    (f:set (f:contains? set item))))

(defun with-entry-crc-preserved (entry f)
  "Call F on ENTRY, restoring its stored CRC afterwards.

   zippy's decode-entry overwrites an entry's stored CRC with its
   local file header value (0 for data-descriptor zips), which would
   break later crc-violations checks; capture it and put it back.
   Must wrap the first decode of ENTRY: the stored CRC is only valid
   before any decoding has clobbered it."
  (let ((stored-crc (z:crc-32 entry)))
    (unwind-protect (funcall f)
      (setf (z:crc-32 entry) stored-crc))))

(defun entry-sha256 (entry)
  "Compute the SHA-256 of ENTRY's decompressed content as a hex string."
  (with-entry-crc-preserved
    entry
    (lambda ()
      (let ((digest (ironclad:make-digest :sha256)))
        (z:decode-entry
          (lambda (buffer start end)
            (ironclad:update-digest digest buffer :start start :end end)
            end)
          entry)
        (bytes->hexstr (ironclad:produce-digest digest))))))

(defun entry-crc (entry)
  "Compute the CRC-32 of ENTRY's decompressed content as an integer."
  (with-entry-crc-preserved
    entry
    (lambda ()
      (let ((digest (ironclad:make-digest :crc32)))
        (z:decode-entry
          (lambda (buffer start end)
            (ironclad:update-digest digest buffer :start start :end end)
            end)
          entry)
        (ironclad:octets-to-integer (ironclad:produce-digest digest))))))

(defun write-entry-with-checksum (entry path)
  "Write ENTRY's content to PATH, returning its SHA-256 as a hex string."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create
                       :element-type '(unsigned-byte 8))
    (let ((digest (ironclad:make-digest :sha256)))
      (z:decode-entry
        (lambda (buffer start end)
          (ironclad:update-digest digest buffer :start start :end end)
          (write-sequence buffer out :start start :end end)
          end)
        entry)
      (bytes->hexstr (ironclad:produce-digest digest)))))

;;; Path helpers

(defun new-unique-path (base pathstr)
  "Return a path under BASE based on PATHSTR that does not already
   exist, appending .1, .2, ... as needed."
  (loop
    for n from 0
    for candidate = (merge-pathnames
                      (if (plusp n)
                          (format nil "~a.~d" pathstr n)
                          pathstr)
                      base)
    unless (uiop:probe-file* candidate)
    return candidate))

(defun backup-all (base paths ending)
  "Move each file in PATHS under BASE to a unique path ending in ENDING."
  (dolist (path paths)
    (let ((ppath (merge-pathnames path base)))
      (when (uiop:file-exists-p ppath)
        (uiop:rename-file-overwriting-target
          ppath
          (new-unique-path base (format nil "~a.~a" ppath ending)))))))

(defun remove-files (base paths)
  "Delete each file in PATHS under BASE, if it exists."
  (dolist (path paths)
    (let ((ppath (merge-pathnames path base)))
      (when (uiop:file-exists-p ppath)
        (uiop:delete-file-if-exists ppath)))))

(defun list-files (dir)
  "Return all entries (files and directories) in directory DIR."
  (append (uiop:directory-files dir)
          (uiop:subdirectories dir)))

(defun all-parents (path)
  "Return PATH followed by each of its parent directories, stopping
   once a directory equals its own parent (the filesystem root)."
  (loop
    for p = path then (uiop:pathname-parent-directory-pathname p)
    while p
    collect p
    until (equal p (uiop:pathname-parent-directory-pathname p))))

(defun entry-name-component (p)
  "Return the last path component of P as a string."
  (if (uiop:directory-pathname-p p)
      (car (last (pathname-directory p)))
      (file-namestring p)))

(defun find-marking-file (start match)
  "Find the first entry named MATCH at or above START, returning its
   pathname, or nil if it is not found or sits too close to the root."
  (let ((found
          (some (lambda (a)
                  (some (lambda (p)
                          (when (string= (entry-name-component p) match)
                            p))
                        (list-files a)))
                (all-parents start))))
    (when (and found
               (uiop:pathname-parent-directory-pathname found)
               (uiop:pathname-parent-directory-pathname
                 (uiop:pathname-parent-directory-pathname found)))
      found)))

;;; Checksums

(defun stream-sha256 (stream)
  "Compute the SHA-256 digest of STREAM as a lowercase hex string."
  (let ((digest (ironclad:make-digest :sha256))
        (buffer (make-array 4096 :element-type '(unsigned-byte 8))))
    (loop
      for n = (read-sequence buffer stream)
      while (plusp n)
      do (ironclad:update-digest digest buffer :end n))
    (bytes->hexstr (ironclad:produce-digest digest))))

(defun stream-crc (stream)
  "Compute the CRC-32 checksum of STREAM as an integer."
  (let ((digest (ironclad:make-digest :crc32))
        (buffer (make-array 4096 :element-type '(unsigned-byte 8))))
    (loop
      for n = (read-sequence buffer stream)
      while (plusp n)
      do (ironclad:update-digest digest buffer :end n))
    (ironclad:octets-to-integer (ironclad:produce-digest digest))))

(defun file-sha256 (path)
  "Compute the SHA-256 of the file at PATH, or nil if it does not exist."
  (when (uiop:file-exists-p path)
    (with-open-file (stream path :direction :input
                            :element-type '(unsigned-byte 8))
      (stream-sha256 stream))))

(defun file-size (path)
  "Return the size in bytes of the file at PATH."
  (with-open-file (stream path :direction :input)
    (file-length stream)))

;;; Archive handling

(defun archive-contents (zip-file)
  "Return the entries of ZIP-FILE as a list of plists with :PATH,
   :SIZE, :TIME, :CRC, and :IS-DIRECTORY.

   NOTE: :TIME is zippy's last-modified, i.e. universal time (seconds
   since the epoch), unlike zic's original epoch milliseconds."
  (gmap:gmap
      (:result list)
    (lambda (entry)
      (list :path (z:file-name entry)
            :size (z:uncompressed-size entry)
            :time (z:last-modified entry)
            :crc (z:crc-32 entry)
            :is-directory (directory-entry-p entry)))
    (:arg :seq (z:entries zip-file))))

(defun archive-entry-checksums (zip-file &optional (path-pred
                                                     (constantly t)))
  "Compute the SHA-256 checksums of the non-directory entries of
   ZIP-FILE matching PATH-PRED, as an fset map of name to checksum."
  (fset:reduce
    (lambda (result entry)
      (if (and (not (directory-entry-p entry))
               (funcall path-pred (z:file-name entry)))
          (f:with result (z:file-name entry) (entry-sha256 entry))
          result))
    (coerce (z:entries zip-file) 'list)
    :initial-value (f:empty-map)))

(defun crc-violations (zip-file)
  "Return the CRC violations of ZIP-FILE as a list of plists with
   :PATH, :STORED-CRC, and :COMPUTED-CRC, one per mismatched entry."
  (gmap:gmap (:result list :filterp :id)
    (lambda (entry)
      (unless (directory-entry-p entry)
        ;; NOTE: zippy's decode-entry overwrites the entry's stored CRC
        ;; with the local file header's value (which is 0 when a data
        ;; descriptor is used), so capture it before computing.  The
        ;; other decode helpers preserve the stored CRC, so this is
        ;; safe no matter what decoding happened before.
        (let ((stored (z:crc-32 entry))
              (computed (entry-crc entry)))
          (unless (eql computed stored)
            (list :path (z:file-name entry)
                  :stored-crc stored
                  :computed-crc computed)))))
    (:arg :vector (z:entries zip-file))))

(defun unpack (zip-file dest &key (put-aside nil)
               (put-aside-ending ".new")
               (exclude nil)
               (exclude-sum-pool nil))
  "Unpack ZIP-FILE to DEST, returning a list of entry plists.

   Each plist has :PATH, :SIZE, :TIME, and :IS-DIRECTORY, plus
   :CHECKSUM when one was computed or supplied. Entries in EXCLUDE are
   not written; entries in PUT-ASIDE are written under a unique path
   ending in PUT-ASIDE-ENDING. Signals an error on CRC violations."
  (let ((violations (crc-violations zip-file)))
    (when violations
      (error "Zip file contains CRC violations: ~a" violations)))
  (gmap:gmap (:result list)
    (lambda (entry)
      (let* ((entry-name (z:file-name entry))
             (base-return (list :path entry-name
                                :size (z:uncompressed-size entry)
                                :time (z:last-modified entry)
                                :is-directory (directory-entry-p entry))))
        (cond
          ((in-set exclude entry-name)
           (let ((exclude-sum
                   (typecase exclude-sum-pool
                     (hash-table (gethash entry-name exclude-sum-pool))
                     (f:map (nth-value 0
                                       (f:lookup exclude-sum-pool entry-name)))
                     (null nil))))
             (if exclude-sum
                 (list* :checksum exclude-sum base-return)
                 base-return)))
          ((directory-entry-p entry)
           (ensure-directories-exist
             (merge-pathnames entry-name dest))
           base-return)
          (t
           (let* ((put-aside-p (in-set put-aside entry-name))
                  (dest-path
                    (if put-aside-p
                        (new-unique-path
                          dest (format nil "~a~a" entry-name
                                       put-aside-ending))
                        (merge-pathnames entry-name dest))))
             (unless put-aside-p
               (uiop:delete-file-if-exists dest-path))
             (list* :checksum
                    (write-entry-with-checksum entry dest-path)
                    base-return))))))
    (:arg :vector (z:entries zip-file))))

;;; Downloading and verification

(defun download (resource dest auth insecure-p)
  "Download RESOURCE to DEST, returning 0 if DEST already exists.

   AUTH is a hash table keyed by host keyword mapping to a hash table
   describing the authorization, with :TYPE one of \"basic\",
   \"header\", or \"oauth-token\". INSECURE-P disables TLS verification."
  (if (uiop:file-exists-p dest)
      0
      (let* ((uri (quri:uri resource))
             (host (quri:uri-host uri))
             (record (when (and host auth)
                       (gethash (intern (string-upcase host) :keyword)
                                auth)))
             (request-args
               (append
                 (when (and record
                            (equal (gethash :type record) "basic"))
                   (list :basic-auth
                         (cons (gethash :username record)
                               (gethash :password record))))
                 (when (and record
                            (equal (gethash :type record) "header"))
                   (list :headers (gethash :headers record)))
                 (when (and record
                            (equal (gethash :type record) "oauth-token"))
                   (list :headers
                         (list (cons "Authorization"
                                     (format nil "Bearer ~a"
                                             (gethash :oauth-token
                                                      record)))))))))
        (let ((body (apply #'dexador:get resource
                           :want-stream t
                           :force-binary t
                           :insecure insecure-p
                           request-args)))
          (unwind-protect
              (with-open-file (out dest :direction :output
                                   :if-exists :supersede
                                   :if-does-not-exist :create
                                   :element-type '(unsigned-byte 8))
                (let ((buffer (make-array 4096
                                          :element-type
                                          '(unsigned-byte 8))))
                  (loop
                    for n = (read-sequence buffer body)
                    while (plusp n)
                    do (write-sequence buffer out :end n))))
            (ignore-errors (close body))))
        dest)))

(defun verify (base path-info)
  "Verify a path on the filesystem against PATH-INFO.

   PATH-INFO is a plist with :PATH, :SIZE, :CLASS, and :CHECKSUM.
   Returns a plist describing the result, e.g. (:RESULT :CORRECT)."
  (destructuring-bind (&key path size class checksum) path-info
    (let* ((target-path (merge-pathnames path base))
           (is-dir (uiop:directory-exists-p target-path))
           (exists (or (uiop:file-exists-p target-path) is-dir)))
      (cond
        ((eql class :ghost-file)
         (if is-dir
             (list :result :path-not-file)
             (list :result :correct)))
        ((eql class :config-file)
         (cond
           (is-dir (list :result :path-not-file))
           (exists (list :result :correct))
           (t (list :result :config-file-missing))))
        ((eql class :directory)
         (if is-dir
             (list :result :correct)
             (list :result :path-not-directory)))
        ((eql class :normal-file)
         (cond
           (is-dir (list :result :path-not-file))
           (exists
            (let ((target-size (file-size target-path)))
              (if (not (= target-size size))
                  (list :result :size-discrepancy
                        :target-path-size target-size)
                  (let ((target-checksum (file-sha256 target-path)))
                    (if (not (string-equal target-checksum checksum))
                        (list :result :checksum-discrepancy
                              :target-checksum target-checksum
                              :source-checksum checksum)
                        (list :result :correct))))))
           (t (list :result :file-missing))))
        (t (error "Unknown file class `~a`." class))))))
