;;;; tests/fs.lisp
;;;;
;;;; Unit tests for the ported filesystem/archive helpers in src/fs.lisp.

(defpackage #:com.djhaskin.zick/tests/fs
  (:use #:cl)
  (:import-from #:com.djhaskin.zick/fs
    #:new-unique-path
    #:backup-all
    #:remove-files
    #:stream-sha256
    #:stream-crc
    #:file-sha256
    #:file-size
    #:archive-entry-checksums
    #:archive-contents
    #:verify
    #:crc-violations
    #:unpack
    #:list-files
    #:find-marking-file)
  (:import-from #:org.shirakumo.zippy
    #:compress-zip
    #:with-zip-file)
  (:import-from #:fset)
  (:import-from #:uiop)
  (:import-from #:ironclad)
  (:import-from #:parachute
    #:define-test
    #:is
    #:true)
  (:local-nicknames
    (#:fs #:com.djhaskin.zick/fs)
    (#:f #:fset)))

(in-package #:com.djhaskin.zick/tests/fs)

;;; Well-known test vectors
;;;
;;; SHA-256("hello") and CRC-32("hello") are standard, widely-known
;;; values (the latter is zlib's CRC-32 of "hello").

(defparameter *sha256-hello*
  "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")

(defparameter *crc32-hello* #x3610a686)

;;; SHA-256 of the empty string, also a standard test vector.
(defparameter *sha256-empty*
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

;;; Test helpers

(defmacro with-temporary-directory ((var) &body body)
  "Bind VAR to a fresh temporary directory for the duration of BODY."
  (let ((dir (gensym "TMP-DIR-")))
    `(let* ((,dir (make-pathname
                    :directory
                    (append (pathname-directory (uiop:temporary-directory))
                            (list (format nil "zick-test-~a"
                                          (random 1000000)))))))
       (ensure-directories-exist ,dir)
       (unwind-protect
           (let ((,var ,dir))
             ,@body)
         (uiop:delete-directory-tree ,dir :validate t
                                     :if-does-not-exist :ignore)))))

(defun string->octets (string)
  "Convert STRING to a simple byte array of its character codes."
  (map '(simple-array (unsigned-byte 8) (*))
       (lambda (char) (char-code char))
       string))

(defun octets->string (octets)
  "Convert a byte array OCTETS to a string."
  (map 'string (lambda (byte) (code-char byte)) octets))

(defun write-bytes (path octets)
  "Write OCTETS to the file at PATH."
  (with-open-file (out path :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create
                       :element-type '(unsigned-byte 8))
    (write-sequence octets out)))

(defun read-bytes (path)
  "Read the file at PATH into a byte array."
  (with-open-file (in path :direction :input
                      :element-type '(unsigned-byte 8))
    (let ((octets (make-array (file-length in)
                              :element-type '(unsigned-byte 8))))
      (read-sequence octets in)
      octets)))

(defun write-text-file (path text)
  "Write TEXT to the file at PATH."
  (write-bytes path (string->octets text)))

(defun read-text-file (path)
  "Return the contents of the file at PATH as a string."
  (octets->string (read-bytes path)))

(defun byte-subseq-position (needle haystack &key (start 0))
  "Return the index of the first occurrence of byte array NEEDLE in
   HAYSTACK at or after START, or nil."
  (let ((n (length needle))
        (h (length haystack)))
    (loop for i from start to (- h n)
          when (loop for j below n
                     always (eql (aref haystack (+ i j)) (aref needle j)))
          return i)))

(defun fixture-dir (dir)
  "Populate DIR with a small file tree and return DIR."
  (ensure-directories-exist (merge-pathnames "sub/" dir))
  (write-text-file (merge-pathnames "a.txt" dir) "hello")
  (write-text-file (merge-pathnames "b.txt" dir) "world")
  (write-text-file (merge-pathnames "sub/c.txt" dir) "sub content")
  dir)

(defun make-zip (dir zip-path)
  "Zip DIR (with names relative to DIR itself) to ZIP-PATH."
  (compress-zip (uiop:ensure-directory-pathname dir)
                zip-path
                :strip-root t
                :if-exists :supersede)
  zip-path)

;;; Checksums

(define-test checksum-streams
  :parent nil
  "stream-sha256 and stream-crc compute correct digests."
  (with-temporary-directory (tmp)
    (let ((path (merge-pathnames "sample" tmp)))
      (write-text-file path "hello")
      (with-open-file (in path :direction :input
                          :element-type '(unsigned-byte 8))
        (is string= *sha256-hello* (stream-sha256 in)))
      (with-open-file (in path :direction :input
                          :element-type '(unsigned-byte 8))
        (is = *crc32-hello* (stream-crc in))))))

(define-test file-sha256
  :parent nil
  "file-sha256 hashes an existing file and returns nil for a missing one."
  (with-temporary-directory (tmp)
    (let ((path (merge-pathnames "sample" tmp)))
      (write-text-file path "hello")
      (is string= *sha256-hello* (file-sha256 path))
      (true (null (file-sha256 (merge-pathnames "no-such-file" tmp)))))))

(defun zlib-crc-of (string)
  "Return the CRC-32 of STRING as an integer, the way zippy stores it."
  (let ((digest (ironclad:make-digest :crc32)))
    (ironclad:update-digest digest (string->octets string))
    (ironclad:octets-to-integer (ironclad:produce-digest digest))))

;;; Archives

(define-test archive-entry-checksums
  :parent nil
  "archive-entry-checksums maps entry names to their SHA-256 digests."
  (with-temporary-directory (tmp)
    (let* ((dir (merge-pathnames "fixture/" tmp))
           (zip-path (merge-pathnames "fixture.zip" tmp))
           (zip-file (make-zip (fixture-dir dir) zip-path)))
      (with-zip-file (zf zip-file)
        (let ((checksums (archive-entry-checksums zf)))
          (is string= *sha256-hello* (fset:lookup checksums "a.txt"))
          (true (not (null (fset:lookup checksums "sub/c.txt")))))))))

(define-test archive-contents-lists-entries
  :parent nil
  "archive-contents returns a plist per entry with path and size."
  (with-temporary-directory (tmp)
    (let* ((dir (merge-pathnames "fixture/" tmp))
           (zip-path (merge-pathnames "fixture.zip" tmp))
           (zip-file (make-zip (fixture-dir dir) zip-path)))
      (with-zip-file (zf zip-file)
        (let* ((contents (archive-contents zf))
               (a (find "a.txt" contents :key (lambda (p) (getf p :path))
                        :test #'string=)))
          (true (not (null a)))
          (is = 5 (getf a :size))
          (is eq nil (getf a :is-directory)))))))

(define-test crc-violations-detect-corruption
  :parent nil
  "crc-violations reports an entry whose stored CRC no longer matches
   its content (a corrupted, uncompressed archive)."
  (with-temporary-directory (tmp)
    (let* ((dir (merge-pathnames "fixture/" tmp))
           (good-zip (make-zip (fixture-dir dir)
                               (merge-pathnames "good.zip" tmp)))
           (bad-zip (merge-pathnames "bad.zip" tmp))
           (good (read-bytes good-zip))
           (pos (byte-subseq-position (string->octets "hello") good)))
      (true (not (null pos)))
      (let ((bad (copy-seq good)))
        (setf (aref bad pos) (char-code #\X))
        (write-bytes bad-zip bad))
      (with-zip-file (zf bad-zip)
        (let ((violations (crc-violations zf)))
          (true (not (null violations)))
          (is string= "a.txt" (getf (first violations) :path))
          (is = (zlib-crc-of "hello")
              (getf (first violations) :stored-crc)))))))

(define-test unpack-writes-files
  :parent nil
  "unpack writes archive entries under DEST and reports checksums."
  (with-temporary-directory (tmp)
    (let* ((dir (merge-pathnames "fixture/" tmp))
           (zip-path (make-zip (fixture-dir dir)
                               (merge-pathnames "fixture.zip" tmp)))
           (dest (merge-pathnames "out/" tmp)))
      (with-zip-file (zf zip-path)
        (let ((results (unpack zf dest)))
          (is string= "hello" (read-text-file (merge-pathnames "a.txt" dest)))
          (is string= "sub content"
              (read-text-file (merge-pathnames "sub/c.txt" dest)))
          (let ((a (find "a.txt" results :key (lambda (p) (getf p :path))
                         :test #'string=)))
            (true (not (null a)))
            (is string= *sha256-hello* (getf a :checksum))))))))

(define-test unpack-puts-existing-files-aside
  :parent nil
  "unpack with :put-aside leaves an existing file alone and writes the
   incoming one to a unique .new path."
  (with-temporary-directory (tmp)
    (let* ((dir (merge-pathnames "fixture/" tmp))
           (zip-path (make-zip (fixture-dir dir)
                               (merge-pathnames "fixture.zip" tmp)))
           (dest (merge-pathnames "out/" tmp)))
      (ensure-directories-exist dest)
      (write-text-file (merge-pathnames "a.txt" dest) "already here")
      (with-zip-file (zf zip-path)
        (unpack zf dest :put-aside (fset:set "a.txt"))
        (is string= "already here"
            (read-text-file (merge-pathnames "a.txt" dest)))
        (true (uiop:file-exists-p
                (merge-pathnames "a.txt.new" dest)))))))

(define-test unpack-excludes-and-pools-checksums
  :parent nil
  "unpack with :exclude skips writing and, with :exclude-sum-pool,
   still reports the known checksum of the skipped entry."
  (with-temporary-directory (tmp)
    (let* ((dir (merge-pathnames "fixture/" tmp))
           (zip-path (make-zip (fixture-dir dir)
                               (merge-pathnames "fixture.zip" tmp)))
           (dest (merge-pathnames "out/" tmp))
           (pool (fset:map ("a.txt" "deadbeef"))))
      (with-zip-file (zf zip-path)
        (let ((results (unpack zf dest
                               :exclude (fset:set "a.txt")
                               :exclude-sum-pool pool)))
          (true (not (uiop:file-exists-p (merge-pathnames "a.txt" dest))))
          (let ((a (find "a.txt" results :key (lambda (p) (getf p :path))
                         :test #'string=)))
            (true (not (null a)))
            (is string= "deadbeef" (getf a :checksum))))))))

(define-test unpack-signals-on-crc-violations
  :parent nil
  "unpack signals an error when the archive has CRC violations."
  (with-temporary-directory (tmp)
    (let* ((dir (merge-pathnames "fixture/" tmp))
           (good-zip (make-zip (fixture-dir dir)
                               (merge-pathnames "good.zip" tmp)))
           (bad-zip (merge-pathnames "bad.zip" tmp))
           (good (read-bytes good-zip))
           (pos (byte-subseq-position (string->octets "hello") good))
           (dest (merge-pathnames "out/" tmp)))
      (let ((bad (copy-seq good)))
        (setf (aref bad pos) (char-code #\X))
        (write-bytes bad-zip bad))
      (true (handler-case
                (progn
                  (with-zip-file (zf bad-zip)
                    (unpack zf dest))
                  nil)
              (error () t))))))

;;; Verification

(define-test verify-normal-files
  :parent nil
  "verify classifies normal files against their recorded info."
  (with-temporary-directory (tmp)
    (write-text-file (merge-pathnames "good" tmp) "hello")
    (is equal '(:result :correct)
        (verify tmp (list :path "good" :size 5 :class :normal-file
                          :checksum *sha256-hello*)))
    (is equal '(:result :size-discrepancy :target-path-size 5)
        (verify tmp (list :path "good" :size 4 :class :normal-file
                          :checksum *sha256-hello*)))
    (is eq :checksum-discrepancy
        (getf (verify tmp (list :path "good" :size 5 :class :normal-file
                                :checksum "deadbeef"))
              :result))
    (is equal '(:result :file-missing)
        (verify tmp (list :path "nope" :size 5 :class :normal-file
                          :checksum *sha256-hello*)))))

(define-test verify-ghost-and-config-files
  :parent nil
  "verify treats ghost files as always-correct and config files as
   optional."
  (with-temporary-directory (tmp)
    (is equal '(:result :correct)
        (verify tmp (list :path "missing" :class :ghost-file)))
    (ensure-directories-exist (merge-pathnames "sub/" tmp))
    (is equal '(:result :path-not-file)
        (verify tmp (list :path "sub" :class :ghost-file)))
    (is equal '(:result :config-file-missing)
        (verify tmp (list :path "conf" :class :config-file)))
    (write-text-file (merge-pathnames "conf" tmp) "data")
    (is equal '(:result :correct)
        (verify tmp (list :path "conf" :class :config-file)))))

(define-test verify-directories
  :parent nil
  "verify checks directories."
  (with-temporary-directory (tmp)
    (ensure-directories-exist (merge-pathnames "sub/" tmp))
    (is equal '(:result :correct)
        (verify tmp (list :path "sub" :class :directory)))
    (is equal '(:result :path-not-directory)
        (verify tmp (list :path "nope" :class :directory)))))

;;; Path helpers

(define-test new-unique-path-appends-numbers
  :parent nil
  "new-unique-path returns a non-existent path, appending .1, .2, ..."
  (with-temporary-directory (tmp)
    (write-text-file (merge-pathnames "thing" tmp) "x")
    (let ((first (new-unique-path tmp "thing")))
      (is equal (merge-pathnames "thing.1" tmp) first)
      (write-text-file first "y")
      (is equal (merge-pathnames "thing.2" tmp)
          (new-unique-path tmp "thing")))))

(define-test backup-and-remove
  :parent nil
  "backup-all renames files to a .bak ending and remove-files deletes."
  (with-temporary-directory (tmp)
    (write-text-file (merge-pathnames "a" tmp) "1")
    (write-text-file (merge-pathnames "b" tmp) "2")
    (backup-all tmp (list "a" "b") "bak")
    (true (not (uiop:file-exists-p (merge-pathnames "a" tmp))))
    (true (uiop:file-exists-p (merge-pathnames "a.bak" tmp)))
    (remove-files tmp (list "a.bak"))
    (true (not (uiop:file-exists-p (merge-pathnames "a.bak" tmp))))))

(define-test find-marking-file-walks-up
  :parent nil
  "find-marking-file locates a named file in an ancestor directory."
  (with-temporary-directory (tmp)
    (let ((proj (merge-pathnames "proj/" tmp)))
      (ensure-directories-exist (merge-pathnames "proj/src/" tmp))
      (write-text-file (merge-pathnames "proj/.zic-db" tmp) "mark")
      (let ((found (find-marking-file (merge-pathnames "proj/src/" tmp)
                                      ".zic-db")))
        (true (not (null found)))
        (is string= ".zic-db" (file-namestring found))))))

(define-test find-marking-file-missing-returns-nil
  :parent nil
  "find-marking-file returns nil when no matching file exists."
  (with-temporary-directory (tmp)
    (let ((proj (merge-pathnames "proj/src/" tmp)))
      (ensure-directories-exist proj)
      (true (null (find-marking-file proj ".zic-db"))))))

;;; Small helpers

(define-test bytes->hexstr-converts
  :parent nil
  "bytes->hexstr emits lowercase zero-padded hex."
  (is string= "ff1001" (fs::bytes->hexstr #(255 16 1)))
  (is string= "" (fs::bytes->hexstr #())))

(define-test in-set-membership
  :parent nil
  "in-set recognizes functions, hash tables, fset sets, and nil."
  (let ((table (make-hash-table :test 'equal)))
    (setf (gethash "a" table) t)
    (true (fs::in-set (lambda (x) (string= x "a")) "a"))
    (true (null (fs::in-set (lambda (x) (string= x "a")) "b")))
    (true (fs::in-set table "a"))
    (true (null (fs::in-set table "b")))
    (true (fs::in-set (fset:set "a") "a"))
    (true (null (fs::in-set (fset:set "a") "b")))
    (true (null (fs::in-set nil "a")))))

(define-test file-size-returns-bytes
  :parent nil
  "file-size returns the byte length of a file."
  (with-temporary-directory (tmp)
    (let ((path (merge-pathnames "sample" tmp)))
      (write-text-file path "hello")
      (is = 5 (file-size path)))))

(define-test stream-sha256-of-empty
  :parent nil
  "stream-sha256 of an empty stream is the empty-file digest."
  (with-temporary-directory (tmp)
    (let ((path (merge-pathnames "empty" tmp)))
      (write-bytes path #())
      (with-open-file (in path :direction :input
                          :element-type '(unsigned-byte 8))
        (is string= *sha256-empty* (stream-sha256 in))))))

;;; Entry-level digests and the stored-CRC invariant

(defun non-directory-entry (zip-file)
  "Return the first non-directory entry of ZIP-FILE."
  (find-if-not
    (lambda (entry) (fs::directory-entry-p entry))
    (coerce (org.shirakumo.zippy:entries zip-file) 'list)))

(define-test entry-sha256-known-vector
  :parent nil
  "entry-sha256 hashes a zip entry's content."
  (with-temporary-directory (tmp)
    (let* ((dir (merge-pathnames "fixture/" tmp))
           (zip-path (make-zip (fixture-dir dir)
                               (merge-pathnames "fixture.zip" tmp))))
      (with-zip-file (zf zip-path)
        (is string= *sha256-hello*
            (fs::entry-sha256 (non-directory-entry zf)))))))

(define-test entry-crc-known-vector
  :parent nil
  "entry-crc computes the CRC-32 of a zip entry's content."
  (with-temporary-directory (tmp)
    (let* ((dir (merge-pathnames "fixture/" tmp))
           (zip-path (make-zip (fixture-dir dir)
                               (merge-pathnames "fixture.zip" tmp))))
      (with-zip-file (zf zip-path)
        (is = *crc32-hello*
            (fs::entry-crc (non-directory-entry zf)))))))

(define-test decode-preserves-stored-crc
  :parent nil
  "Decoding an entry out-of-band (as upgrade-existing-package does for
   checksums) must not break a later crc-violations check: zippy's
   decode-entry would otherwise clobber the stored CRC."
  (with-temporary-directory (tmp)
    (let* ((dir (merge-pathnames "fixture/" tmp))
           (zip-path (make-zip (fixture-dir dir)
                               (merge-pathnames "fixture.zip" tmp))))
      (with-zip-file (zf zip-path)
        (fs::entry-sha256 (non-directory-entry zf))
        (is equal '() (crc-violations zf))))))

(define-test directory-entry-p-classifies
  :parent nil
  "directory-entry-p distinguishes directory entries from files."
  (with-temporary-directory (tmp)
    (let* ((dir (merge-pathnames "fixture/" tmp))
           (zip-path (make-zip (fixture-dir dir)
                               (merge-pathnames "fixture.zip" tmp))))
      (with-zip-file (zf zip-path)
        (let* ((entries (coerce (org.shirakumo.zippy:entries zf) 'list))
               (a (find "a.txt" entries
                        :key (lambda (e)
                               (org.shirakumo.zippy:file-name e))
                        :test #'string=)))
          (true (not (null a)))
          (true (null (fs::directory-entry-p a)))
          ;; The fixture has a subdirectory, so some entry is a dir.
          (true (some #'fs::directory-entry-p entries)))))))

;;; Directory helpers

(define-test list-files-includes-files-and-dirs
  :parent nil
  "list-files returns the files and subdirectories of a directory."
  (with-temporary-directory (tmp)
    (let* ((dir (fixture-dir (merge-pathnames "fixture/" tmp)))
           (entries (list-files dir))
           (names (mapcar #'file-namestring entries)))
      ;; a.txt, b.txt, and the sub/ directory (not its contents).
      (is = 3 (length entries))
      (true (member "a.txt" names :test #'string=))
      (true (member "b.txt" names :test #'string=))
      (true (some #'uiop:directory-pathname-p entries)))))

(define-test all-parents-reaches-root
  :parent nil
  "all-parents walks from a path up through its ancestors, without
   collecting nil."
  (with-temporary-directory (tmp)
    (let* ((start (merge-pathnames "a/b/" tmp))
           (parents (fs:all-parents start)))
      (is equal start (first parents))
      (true (member tmp parents :test #'equal))
      (true (null (member nil parents))))))

;;; unpack details

(define-test unpack-overwrites-existing-normal-file
  :parent nil
  "unpack replaces an existing non-put-aside file with the archive
   content."
  (with-temporary-directory (tmp)
    (let* ((dir (merge-pathnames "fixture/" tmp))
           (zip-path (make-zip (fixture-dir dir)
                               (merge-pathnames "fixture.zip" tmp)))
           (dest (merge-pathnames "out/" tmp)))
      (ensure-directories-exist dest)
      (write-text-file (merge-pathnames "a.txt" dest) "stale")
      (with-zip-file (zf zip-path)
        (unpack zf dest))
      (is string= "hello"
          (read-text-file (merge-pathnames "a.txt" dest))))))

(define-test backup-all-missing-is-noop
  :parent nil
  "backup-all ignores paths that do not exist."
  (with-temporary-directory (tmp)
    (backup-all tmp (list "no-such-file") "bak")
    (true (null (uiop:directory-files tmp)))))

;;; verify details

(define-test verify-size-zero-file
  :parent nil
  "verify accepts an existing empty normal file of size 0."
  (with-temporary-directory (tmp)
    (write-bytes (merge-pathnames "empty" tmp) #())
    (is equal '(:result :correct)
        (verify tmp
                (list :path "empty" :size 0 :class :normal-file
                      :checksum *sha256-empty*)))))

(define-test verify-normal-file-path-not-file
  :parent nil
  "verify reports a directory where a normal file is expected."
  (with-temporary-directory (tmp)
    (ensure-directories-exist (merge-pathnames "adir/" tmp))
    (is equal '(:result :path-not-file)
        (verify tmp (list :path "adir" :size 1 :class :normal-file
                          :checksum "x")))))
