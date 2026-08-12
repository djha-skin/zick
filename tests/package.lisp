;;;; tests/package.lisp
;;;;
;;;; Unit and integration tests for the ported package layer in
;;;; src/package.lisp, mirroring zic's test/zic/package_test.clj and
;;;; exercising install/remove/verify against real temporary stores.

(defpackage #:com.djhaskin.zick/tests/package
  (:use #:cl)
  (:import-from #:com.djhaskin.zick/package
    #:verify-package-files
    #:get-package-files
    #:get-package-info
    #:get-package-dependees
    #:get-package-dependers
    #:download-package
    #:decide-config-fate
    #:package-file-conflicts
    #:config-and-upgrade-precautions
    #:install-package
    #:remove-package
    #:reachable-nodes
    #:sinks
    #:linearize)
  (:import-from #:com.djhaskin.zick/db)
  (:import-from #:com.djhaskin.zick/fs)
  (:import-from #:fset)
  (:import-from #:uiop)
  (:import-from #:usocket)
  (:import-from #:bordeaux-threads)
  (:import-from #:flexi-streams)
  (:import-from #:org.shirakumo.zippy
    #:compress-zip
    #:with-zip-file)
  (:import-from #:parachute
    #:define-test
    #:is
    #:true)
  (:local-nicknames
    (#:package #:com.djhaskin.zick/package)
    (#:db #:com.djhaskin.zick/db)
    (#:fs #:com.djhaskin.zick/fs)
    (#:f #:fset)))

(in-package #:com.djhaskin.zick/tests/package)

;;; Test helpers

;;; SHA-256("hello"), a well-known test vector.
(defparameter *sha256-hello*
  "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")

(defun temporary-dir (prefix)
  "A fresh temporary directory path with PREFIX, not yet created."
  (uiop:ensure-directory-pathname
    (merge-pathnames
      (format nil "~a-~d/" prefix (random 1000000))
      (uiop:temporary-directory))))

(defun write-text-file (path text)
  "Write TEXT to the file at PATH."
  (with-open-file (out path :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create)
    (write-string text out)))

(defun write-text-bytes (path text)
  "Write TEXT to the file at PATH as raw bytes (for zip fixtures)."
  (with-open-file (out path :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create
                       :element-type '(unsigned-byte 8))
    (write-sequence (map '(simple-array (unsigned-byte 8) (*))
                         (lambda (char) (char-code char))
                         text)
                    out)))

(defun read-text-file (path)
  "Return the contents of the file at PATH as a string."
  (with-open-file (in path :direction :input
                      :element-type '(unsigned-byte 8))
    (let ((octets (make-array (file-length in)
                              :element-type '(unsigned-byte 8))))
      (read-sequence octets in)
      (map 'string #'code-char octets))))

(defun config-metadata (&optional (config-files '("conf.txt")))
  "A metadata map declaring CONF-FILES as config files."
  (f:map (:zick
           (f:map (:config-files
                    (f:convert 'fset:seq config-files))))))

(defun project-dir (root)
  "The project directory under ROOT."
  (merge-pathnames "proj/" root))

(defun source-dir (root)
  "The package source directory under ROOT."
  (merge-pathnames "pkg-src/" root))

(defun install-options (root package-name &key (version "0.1.0")
                        (dependencies nil)
                        (metadata nil)
                        (download-package nil)
                        (location
                          "https://example.com/pkg.zip"))
  "Return an options plist installing PACKAGE-NAME into the project
   rooted at ROOT."
  (list :package-name package-name
        :package-version version
        :package-location location
        :package-metadata metadata
        :package-dependency dependencies
        :download-package download-package
        :db-connection-string
        (uiop:native-namestring (merge-pathnames ".zick-db/" root))
        :root-path root
        :lock-path (merge-pathnames ".zick.lock" root)))

(defun make-zip (root source-dir zip-name)
  "Zip SOURCE-DIR (with names relative to it) to ZIP-NAME under ROOT."
  (compress-zip (uiop:ensure-directory-pathname source-dir)
                (merge-pathnames zip-name root)
                :strip-root t
                :if-exists :supersede)
  (merge-pathnames zip-name root))

(defun precautions-options (root name version)
  "An options plist for a precaution test of NAME VERSION at ROOT."
  (list :package-name name
        :package-version version
        :package-metadata (config-metadata)
        :root-path root))

(defun store-with-files (name version files
                         &key (config-files '("conf.txt")))
  "A store with package NAME VERSION owning FILES, with
   CONFIG-FILES declared as config files."
  (db:add-package (db:empty-store)
                  (list :package-name name
                        :package-version version
                        :package-location "loc"
                        :package-metadata (config-metadata config-files))
                  files
                  nil))

(defun download-install-options (root url name
                                 &key (version "0.1.0") metadata)
  "An options plist installing NAME from the local URL URL with
   :download-package t and a staging directory under ROOT."
  (list* :package-location url
         :download-package t
         :staging-path (merge-pathnames "staging/" root)
         (install-options root name
                          :version version
                          :metadata metadata)))

(defun config-store (name version)
  "A store with package NAME VERSION owning one config file."
  (store-with-files
    name version
    (list (list :path "conf.txt" :size 10
                :is-directory nil :checksum "old"))))

(defun asserts-refusal (options store zip-path search-text)
  "True when config-and-upgrade-precautions on ZIP-PATH signals an
   error containing SEARCH-TEXT."
  (with-zip-file (zf zip-path)
    (handler-case
        (progn
          (package:config-and-upgrade-precautions
            options store zf (fs:archive-contents zf))
          nil)
      (error (e)
        (search search-text (princ-to-string e))))))

;;; Throwaway HTTP server (for the download-package tests)

(defun read-file-bytes (path)
  "Return the bytes of the file at PATH as a byte array."
  (with-open-file (in path :direction :input
                      :element-type '(unsigned-byte 8))
    (let ((octets (make-array (file-length in)
                              :element-type '(unsigned-byte 8))))
      (read-sequence octets in)
      octets)))

(defun http-serve-once (path)
  "Serve the file at PATH over one HTTP GET on an ephemeral local
   port, returning the URL to fetch it from.

   A background thread accepts a single connection, reads the request
   headers, and replies with the file bytes (Content-Length set).  The
   binary socket is wrapped in a latin-1 flexi-stream so arbitrary
   bytes round-trip unchanged.  The caller fetches the URL; the thread
   finishes on its own."
  (let* ((server (usocket:socket-listen "127.0.0.1" 0 :reuse-address t))
         (port (usocket:get-local-port server))
         (url (format nil "http://127.0.0.1:~d/~a"
                      port (file-namestring path))))
    (bt:make-thread
      (lambda ()
        (unwind-protect
            (handler-case
                (let* ((conn (usocket:socket-accept
                               server :element-type '(unsigned-byte 8)))
                       (binary (usocket:socket-stream conn))
                       (stream (flexi-streams:make-flexi-stream
                                 binary :external-format :latin-1)))
                  (unwind-protect
                      (progn
                        ;; Read the request headers until the blank line.
                        (loop for line = (read-line stream nil nil)
                              while (and line
                                         (plusp (length
                                                  (string-trim
                                                    '(#\Return #\Newline)
                                                    line)))))
                        (let* ((octets (read-file-bytes path))
                               (crlf (format nil "~C~C" #\Return #\Newline))
                               (header (concatenate
                                         'string
                                         "HTTP/1.1 200 OK" crlf
                                         "Content-Length: "
                                         (write-to-string (length octets))
                                         crlf "Connection: close" crlf crlf)))
                          (write-string header stream)
                          (write-string (map 'string #'code-char octets)
                                        stream)
                          (finish-output stream)))
                    (ignore-errors (close stream))))
              (error () nil))
          (ignore-errors (usocket:socket-close server))))
      :name "zick-test-http")
    url))

(defun http-serve-once-auth (path &key (connections 1))
  "Serve the file at PATH over CONNECTIONS HTTP GETs on an ephemeral
   local port, demanding HTTP basic auth (user MODE, password CODE)
   and replying 401 otherwise.  Returns the URL to fetch it from.

   Like http-serve-once, but for exercising download authorizations.
   Pass CONNECTIONS when the caller will fetch more than once (e.g.
   a refused attempt followed by an authorized one)."
  (let* ((server (usocket:socket-listen "127.0.0.1" 0 :reuse-address t))
         (port (usocket:get-local-port server))
         (url (format nil "http://127.0.0.1:~d/~a"
                      port (file-namestring path))))
    (bt:make-thread
      (lambda ()
        (unwind-protect
            (handler-case
                (loop repeat connections do
                      (let* ((conn (usocket:socket-accept
                                     server :element-type '(unsigned-byte 8)))
                             (binary (usocket:socket-stream conn))
                             (stream (flexi-streams:make-flexi-stream
                                       binary :external-format :latin-1))
                             (crlf (format nil "~C~C" #\Return #\Newline)))
                        (unwind-protect
                            (progn
                              ;; Read the request headers, looking for the
                              ;; expected basic-auth header (base64 of
                              ;; "mode:code").
                              (let ((authorized nil))
                                (loop for line = (read-line stream nil nil)
                                      while (and line
                                                 (plusp (length
                                                          (string-trim
                                                            '(#\Return
                                                              #\Newline)
                                                            line))))
                                      do (when (and (null authorized)
                                                    (search
                                                      "Authorization: Basic"
                                                      line))
                                           ;; bW9kZTpjb2Rl = base64 of
                                           ;; "mode:code".
                                           (setf authorized
                                                 (search
                                                   "bW9kZTpjb2Rl" line))))
                                (if authorized
                                    (let* ((octets (read-file-bytes path))
                                           (header
                                             (concatenate
                                               'string
                                               "HTTP/1.1 200 OK" crlf
                                               "Content-Length: "
                                               (write-to-string
                                                 (length octets))
                                               crlf "Connection: close"
                                               crlf crlf)))
                                      (write-string header stream)
                                      (write-string
                                        (map 'string #'code-char octets)
                                        stream)
                                      (finish-output stream))
                                    (let ((header
                                            (concatenate
                                              'string
                                              "HTTP/1.1 401 Unauthorized" crlf
                                              "Content-Length: 0" crlf
                                              "Connection: close" crlf crlf)))
                                      (write-string header stream)
                                      (finish-output stream)))))
                          (ignore-errors (close stream)))))
              (error () nil))
          (ignore-errors (usocket:socket-close server))))
      :name "zick-test-http-auth")
    url))

;;; Graph linearization (zic's package_test.clj)

(defun fighter (node)
  "The fighter graph from zic's tests."
  (cdr (assoc node '((:c . (:a :b))
                     (:m . (:n :o :p))
                     (:n)
                     (:o)
                     (:p)
                     (:u . (:v :w :x))
                     (:v)
                     (:w)
                     (:x)
                     (:b . (:a :d))
                     (:d . (:e))
                     (:e)
                     (:a . (:u))))))

(defun basic (node)
  "The basic graph from zic's tests."
  (cdr (assoc node '((:c . (:a :b)) (:b . (:a)) (:a)))))

(defun no-edges (node)
  "A graph with no edges."
  (declare (ignore node))
  nil)

(defun cycle-case (node)
  "The cycle graph from zic's tests."
  (cdr (assoc node '((:c . (:a :b)) (:b . (:a)) (:a . (:b))))))

(define-test linearize-empty
  :parent nil
  "linearize of a lone node is that node."
  (is equal '(:c) (package:linearize #'no-edges :c)))

(define-test linearize-basic
  :parent nil
  "linearize lists sinks first in a chain."
  (is equal '(:a :b :c) (package:linearize #'basic :c)))

(define-test linearize-fighter
  :parent nil
  "linearize walks the fighter graph, sinks first."
  (is equal '(:e :v :w :x :d :u :a :b :c)
      (package:linearize #'fighter :c)))

(define-test linearize-cycle
  :parent nil
  "linearize breaks a cycle by listing all remaining nodes at once."
  (is equal '(:a :b :c) (package:linearize #'cycle-case :c)))

;;; decide-config-fate

(define-test decide-config-fate
  :parent nil
  "decide-config-fate classifies the four config-file situations."
  (is eq :install (package:decide-config-fate "old" nil "new"))
  (is eq :put-aside (package:decide-config-fate nil "cur" "new"))
  (is eq :do-nothing (package:decide-config-fate "old" "cur" nil))
  ;; current differs from both old and new: keep it, stash the new.
  (is eq :put-aside (package:decide-config-fate "old" "cur" "new"))
  ;; current was locally edited but the archive matches old: keep it.
  (is eq :do-nothing (package:decide-config-fate "old" "cur" "old"))
  ;; otherwise install.
  (is eq :install (package:decide-config-fate "same" "same" "new"))
  (is eq :install (package:decide-config-fate "same" "same" "same")))

;;; package-file-conflicts

(define-test package-file-conflicts
  :parent nil
  "package-file-conflicts flags files owned by other packages."
  (let* ((store (db:add-package
                  (db:empty-store)
                  (list :package-name "a"
                        :package-version "0.1.0"
                        :package-location "loc"
                        :package-metadata nil)
                  (list (list :path "f.txt"
                              :size 1
                              :is-directory nil
                              :checksum "c"))
                  nil))
         (new-files (list (list :path "f.txt"
                                :is-directory nil))))
    ;; The owning package itself is not a conflict.
    (is equal '()
        (package:package-file-conflicts store "a" new-files))
    ;; Another package is, and the conflict names the owner.
    (let ((conflicts (package:package-file-conflicts
                       store "b" new-files)))
      (is = 1 (length conflicts))
      (is string= "a" (getf (first conflicts) :package))
      (is string= "f.txt" (getf (first conflicts) :path)))
    ;; Directory entries are skipped.
    (is equal '()
        (package:package-file-conflicts
          store "b" (list (list :path "f.txt"
                                :is-directory t))))))

;;; config-and-upgrade-precautions

(define-test config-precautions-fresh-install
  :parent nil
  "A fresh install puts aside config files already present on disk."
  (let* ((root (temporary-dir "zick-fresh-install"))
         (proj (project-dir root))
         (options (precautions-options proj "a" "0.2.0")))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (ensure-directories-exist proj)
          (write-text-file (merge-pathnames "conf.txt" proj)
                           "keep me")
          (multiple-value-bind (precautions updated-store)
                               (package:config-and-upgrade-precautions
                                 options (db:empty-store) nil '())
            (true (f:contains?
                    (getf precautions :put-aside)
                    "conf.txt"))
            (true (null (getf precautions :config-sums)))
            (true (db:store-p updated-store))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test config-precautions-upgrade
  :parent nil
  "Upgrading puts aside a config file differing from both the old and
   new checksums, deletes the old normal files, and clears the old
   package's records."
  (let* ((root (temporary-dir "zick-upgrade"))
         (proj (project-dir root))
         (src (source-dir root))
         (metadata (config-metadata))
         (old-store
           (store-with-files
             "a" "0.1.0"
             (list (list :path "conf.txt" :size 10
                         :is-directory nil
                         :checksum "old-checksum")
                   (list :path "app.txt" :size 5
                         :is-directory nil
                         :checksum "app-checksum")))))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (ensure-directories-exist src)
          (write-text-bytes (merge-pathnames "conf.txt" src)
                            "new config")
          (write-text-bytes (merge-pathnames "app.txt" src) "app")
          (ensure-directories-exist proj)
          (write-text-file (merge-pathnames "conf.txt" proj)
                           "current config")
          (write-text-file (merge-pathnames "app.txt" proj)
                           "old app")
          (let* ((zip-path (make-zip root src "pkg.zip"))
                 (options (precautions-options proj "a" "0.2.0")))
            (with-zip-file (zf zip-path)
              (multiple-value-bind (precautions updated-store)
                                   (package:config-and-upgrade-precautions
                                     options old-store zf
                                     (fs:archive-contents zf))
                ;; conf.txt differs from both old and new.
                (true (f:contains?
                        (getf precautions :put-aside)
                        "conf.txt"))
                ;; The old config checksum is pooled for the unpack.
                (is string= "old-checksum"
                    (f:lookup (getf precautions :config-sums)
                              "conf.txt"))
                ;; The old package's records are gone from the store.
                (true (null (db:owned-by-p
                              updated-store "conf.txt")))
                (is = 0 (length (db:package-files
                                  updated-store "a")))
                ;; The old normal file was deleted from disk.
                (true (not (uiop:file-exists-p
                             (merge-pathnames "app.txt" proj))))))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test config-precautions-refuses-inplace
  :parent nil
  "Replacing a package with the same version is refused unless
   :ALLOW-INPLACE is set."
  (let* ((root (temporary-dir "zick-inplace"))
         (src (source-dir root))
         (store (config-store "a" "0.1.0"))
         (options (list :package-name "a"
                        :package-version "0.1.0"
                        :package-metadata (config-metadata)
                        :root-path (project-dir root))))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (ensure-directories-exist src)
          (write-text-bytes (merge-pathnames "conf.txt" src) "new")
          (let ((zip-path (make-zip root src "pkg.zip")))
            (true (asserts-refusal
                    options store zip-path "allow-inplace"))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test config-precautions-refuses-downgrade
  :parent nil
  "Installing an older version is refused unless :ALLOW-DOWNGRADES is
   set."
  (let* ((root (temporary-dir "zick-downgrade"))
         (src (source-dir root))
         (store (config-store "a" "0.2.0"))
         (options (list :package-name "a"
                        :package-version "0.1.0"
                        :package-metadata (config-metadata)
                        :root-path (project-dir root))))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (ensure-directories-exist src)
          (write-text-bytes (merge-pathnames "conf.txt" src) "new")
          (let ((zip-path (make-zip root src "pkg.zip")))
            (true (asserts-refusal
                    options store zip-path "allow-downgrades"))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

;;; install-package

(define-test install-package-records-package
  :parent nil
  "install-package records a package (with files when downloading is
   disabled, just the record) and persists it to the store file."
  (let* ((root (temporary-dir "zick-install"))
         (opts (install-options root "a")))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (package:install-package opts)
          (let ((info (package:get-package-info opts)))
            (is string= "a" (getf info :name))
            (is string= "0.1.0" (getf info :version))
            (is string= "https://example.com/pkg.zip"
                (getf info :location)))
          (true (uiop:file-exists-p
                  (merge-pathnames ".zick-db/packages.nrdl" root))))
      (uiop:delete-directory-tree root :validate t))))

(define-test install-package-unmet-dependency
  :parent nil
  "install-package refuses to install when a dependency is missing."
  (let* ((root (temporary-dir "zick-unmet"))
         (opts (install-options root "b"
                                :dependencies (list "a"))))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (true (handler-case
                    (progn (package:install-package opts) nil)
                  (error (e)
                    (search "Several dependencies are unmet"
                            (princ-to-string e))))))
      (uiop:delete-directory-tree root :validate t))))

(define-test install-package-met-dependency
  :parent nil
  "install-package records the dependency of a package."
  (let* ((root (temporary-dir "zick-met"))
         (opts-a (install-options root "a")))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (package:install-package opts-a)
          (let* ((opts-b
                   (install-options root "b"
                                    :dependencies (list "a"))))
            (package:install-package opts-b)
            (let* ((dependees
                     (package:get-package-dependees opts-b)))
              (is = 1 (length dependees))
              (is string= "a" (getf (first dependees) :name))))
          (let* ((dependers
                   (package:get-package-dependers
                     (install-options root "a"))))
            (is = 1 (length dependers))
            (is string= "b" (getf (first dependers) :name))))
      (uiop:delete-directory-tree root :validate t))))

;;; Downloading (local HTTP server)

(defun write-source-fixture (src files)
  "Write FILES (alist of path to content) under SRC."
  (ensure-directories-exist src)
  (dolist (pair files)
    (write-text-bytes (merge-pathnames (car pair) src)
                      (cdr pair)))
  src)

(define-test install-package-downloads-from-url
  :parent nil
  "install-package with :download-package downloads the archive from
   the URL, unpacks it into the project, records the files, and keeps
   the staged zip in the staging directory."
  (let* ((root (temporary-dir "zick-download"))
         (src (source-dir root))
         (proj (project-dir root))
         (zip-path (make-zip
                     root (write-source-fixture
                            src '(("app.txt" . "app content")
                                  ("conf.txt" . "new config")))
                     "pkg.zip"))
         (url (http-serve-once zip-path))
         (opts (download-install-options proj url "a"
                                         :metadata (config-metadata))))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (ensure-directories-exist proj)
          ;; conf.txt already exists in the project: it is put aside.
          (write-text-file (merge-pathnames "conf.txt" proj)
                           "keep me")
          (package:install-package opts)
          ;; The package and its files were recorded.
          (let ((info (package:get-package-info opts)))
            (is string= "a" (getf info :name))
            (is string= url (getf info :location)))
          (let* ((files (package:get-package-files opts))
                 (paths (mapcar (lambda (p) (getf p :path)) files)))
            (is = 2 (length files))
            (true (member "app.txt" paths :test #'string=))
            (true (member "conf.txt" paths :test #'string=)))
          ;; The archive was unpacked into the project; the existing
          ;; conf.txt was left alone and the incoming one put aside.
          (is string= "app content"
              (read-text-file (merge-pathnames "app.txt" proj)))
          (is string= "keep me"
              (read-text-file (merge-pathnames "conf.txt" proj)))
          (is string= "new config"
              (read-text-file
                (merge-pathnames "conf.txt.a.0.1.0.new" proj)))
          ;; The staged zip was kept in the staging directory.
          (true (uiop:file-exists-p
                  (merge-pathnames "pkg.zip"
                                   (merge-pathnames "staging/" proj)))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test download-package-fetches-to-staging
  :parent nil
  "download-package downloads the URL to the staging directory under
   the URL's last path component and returns an open zip of it."
  (let* ((root (temporary-dir "zick-dl-stage"))
         (src (source-dir root))
         (zip-path (make-zip
                     root (write-source-fixture
                            src '(("app.txt" . "app content")))
                     "pkg.zip"))
         (url (http-serve-once zip-path))
         (staging (merge-pathnames "staging/" root))
         (opts (list :package-name "a"
                     :package-version "0.1.0"
                     :package-location url
                     :staging-path staging)))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (let ((zip (package:download-package opts)))
            (unwind-protect
                (let ((contents (fs:archive-contents zip)))
                  (is = 1 (length contents))
                  (is string= "app.txt"
                      (getf (first contents) :path)))
              (close zip)))
          ;; Staged under the URL's last path component.
          (true (uiop:file-exists-p
                  (merge-pathnames "pkg.zip" staging))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test download-package-fallback-filename
  :parent nil
  "download-package names the staged file NAME-VERSION.zip when the
   URL has no path component."
  (let* ((root (temporary-dir "zick-dl-fallback"))
         (src (source-dir root))
         (zip-path (make-zip
                     root (write-source-fixture
                            src '(("app.txt" . "app content")))
                     "pkg.zip"))
         (staging (merge-pathnames "staging/" root))
         (url (http-serve-once zip-path))
         (bare-url (concatenate
                     'string
                     (subseq url 0 (position #\/ url :from-end t))
                     "/"))
         (opts (list :package-name "a"
                     :package-version "0.1.0"
                     :package-location bare-url
                     :staging-path staging)))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (let ((zip (package:download-package opts)))
            (unwind-protect
                (let ((contents (fs:archive-contents zip)))
                  (is = 1 (length contents)))
              (close zip)))
          (true (uiop:file-exists-p
                  (merge-pathnames "a-0.1.0.zip" staging))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test download-package-requires-name-version-location
  :parent nil
  "download-package signals unless name, version, and location are all
   given."
  (let* ((root (temporary-dir "zick-dl-required"))
         (staging (merge-pathnames "staging/" root)))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (true (handler-case
                    (progn
                      (package:download-package
                        (list :package-name "a"
                              :package-version "0.1.0"
                              :staging-path staging))
                      nil)
                  (error (e)
                    (search "must all be given"
                            (princ-to-string e))))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

;;; On-disk upgrade and removal effects

(defun seed-store (root store)
  "Persist STORE at ROOT's .zick-db directory (the connection string
   install-options uses)."
  (ensure-directories-exist (merge-pathnames ".zick-db/" root))
  (db:save-store (merge-pathnames ".zick-db/packages.nrdl" root)
                 store))

(define-test install-package-upgrade-backs-up-on-disk
  :parent nil
  "Upgrading via download backs up old config files absent from the
   new version on disk (as name.version.backup), deletes old normal
   files, puts aside edited configs, and unpacks the new files."
  (let* ((root (temporary-dir "zick-upgrade-dl"))
         (proj (project-dir root))
         (src (source-dir root))
         (zip-path (make-zip
                     root (write-source-fixture
                            src '(("app.txt" . "new app")
                                  ("conf.txt" . "new config")))
                     "pkg.zip"))
         (url (http-serve-once zip-path))
         (opts (download-install-options proj url "a"
                                         :version "0.2.0"
                                         :metadata (config-metadata)))
         (old-store
           (store-with-files
             "a" "0.1.0"
             (list (list :path "conf.txt" :size 10
                         :is-directory nil
                         :checksum "old-checksum")
                   (list :path "oldconf.txt" :size 9
                         :is-directory nil
                         :checksum "oldconf-checksum")
                   (list :path "app.txt" :size 5
                         :is-directory nil
                         :checksum "app-checksum"))
             :config-files '("conf.txt" "oldconf.txt"))))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (ensure-directories-exist proj)
          (seed-store proj old-store)
          ;; The old version's files on disk, conf.txt locally edited.
          (write-text-file (merge-pathnames "conf.txt" proj)
                           "current config")
          (write-text-file (merge-pathnames "oldconf.txt" proj)
                           "old conf")
          (write-text-file (merge-pathnames "app.txt" proj)
                           "old app")
          (package:install-package opts)
          ;; oldconf.txt is not in the new version: it was backed up
          ;; on disk, pinning fs:backup-all with fset sets.
          (true (not (uiop:file-exists-p
                       (merge-pathnames "oldconf.txt" proj))))
          (is string= "old conf"
              (read-text-file
                (merge-pathnames "oldconf.txt.a.0.1.0.backup" proj)))
          ;; The old normal file was deleted and the new one unpacked.
          (is string= "new app"
              (read-text-file (merge-pathnames "app.txt" proj)))
          ;; conf.txt was edited on disk: it is kept and the incoming
          ;; one was put aside next to it.
          (is string= "current config"
              (read-text-file (merge-pathnames "conf.txt" proj)))
          (is string= "new config"
              (read-text-file
                (merge-pathnames "conf.txt.a.0.2.0.new" proj))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

;;; remove-package

(define-test remove-package-removes
  :parent nil
  "remove-package returns the removed package and persists the
   removal."
  (let* ((root (temporary-dir "zick-remove"))
         (opts (install-options root "a")))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (package:install-package opts)
          (let ((removed (package:remove-package opts)))
            (is = 1 (length removed))
            (is string= "a" (getf (first removed) :name))
            (true (null (package:get-package-info opts)))))
      (uiop:delete-directory-tree root :validate t))))

(define-test remove-package-not-found
  :parent nil
  "remove-package returns nil for a package that is not installed."
  (let* ((root (temporary-dir "zick-remnot"))
         (opts (install-options root "nope")))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (true (null (package:remove-package opts))))
      (uiop:delete-directory-tree root :validate t))))

(define-test remove-package-refuses-with-dependers
  :parent nil
  "remove-package without :CASCADE refuses when other packages depend
   on the one to be removed, naming the dependers."
  (let* ((root (temporary-dir "zick-refuse"))
         (opts-a (install-options root "a")))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (package:install-package opts-a)
          (package:install-package
            (install-options root "b" :dependencies (list "a")))
          (let ((msg (handler-case
                         (progn (package:remove-package opts-a) nil)
                       (error (e) (princ-to-string e)))))
            (true (search "cannot remove: b" msg))))
      (uiop:delete-directory-tree root :validate t))))

(define-test remove-package-refusal-lists-all-dependers
  :parent nil
  "remove-package's refusal error names every package that depends on
   the one to be removed, comma-joined."
  (let* ((root (temporary-dir "zick-refuse-many"))
         (opts-a (install-options root "a")))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (package:install-package opts-a)
          (package:install-package
            (install-options root "b" :dependencies (list "a")))
          (package:install-package
            (install-options root "c" :dependencies (list "a")))
          (let ((msg (handler-case
                         (progn (package:remove-package opts-a) nil)
                       (error (e) (princ-to-string e)))))
            (true (search "cannot remove: " msg))
            (true (or (search "b, c" msg) (search "c, b" msg)))))
      (uiop:delete-directory-tree root :validate t))))

(define-test remove-package-cascade
  :parent nil
  "remove-package with :CASCADE removes the package and everything
   that depends on it, dependers first."
  (let* ((root (temporary-dir "zick-cascade"))
         (opts-a (install-options root "a")))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (package:install-package opts-a)
          (package:install-package
            (install-options root "b"
                             :dependencies (list "a")))
          (let* ((opts-cascade
                   (append (list :cascade t) opts-a))
                 (removed
                   (package:remove-package opts-cascade)))
            (is = 2 (length removed))
            (is string= "b" (getf (first removed) :name))
            (is string= "a" (getf (second removed) :name))
            (true (null (package:get-package-info opts-cascade)))
            (true (null
                    (package:get-package-info
                      (install-options root "b"))))))
      (uiop:delete-directory-tree root :validate t))))

(define-test remove-package-dry-run
  :parent nil
  "remove-package with :DRY-RUN reports what would be removed without
   touching the project tree: the package record stays, its files stay
   on disk, and no backup is created."
  (let* ((root (temporary-dir "zick-dryrun"))
         (proj (project-dir root))
         (src (source-dir root))
         (zip-path (make-zip
                     root (write-source-fixture
                            src '(("app.txt" . "app content")
                                  ("conf.txt" . "config content")))
                     "pkg.zip"))
         (url (http-serve-once zip-path))
         (opts (download-install-options proj url "a"
                                         :metadata (config-metadata))))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (ensure-directories-exist proj)
          (package:install-package opts)
          (let* ((opts-dry (append (list :dry-run t) opts))
                 (removed (package:remove-package opts-dry)))
            (is = 1 (length removed))
            ;; The package record is still present.
            (true (not (null
                         (package:get-package-info opts-dry))))
            ;; The files are still on disk, no backup was made.
            (true (uiop:file-exists-p
                    (merge-pathnames "app.txt" proj)))
            (true (uiop:file-exists-p
                    (merge-pathnames "conf.txt" proj)))
            (true (not (uiop:file-exists-p
                         (merge-pathnames "conf.txt.a.0.1.0.backup"
                                          proj))))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test remove-package-cascade-dry-run
  :parent nil
  "remove-package with :CASCADE and :DRY-RUN reports the full removal
   set (dependers first) without removing anything."
  (let* ((root (temporary-dir "zick-dryrun-cascade"))
         (proj (project-dir root))
         (src-a (merge-pathnames "pkg-a/" root))
         (src-b (merge-pathnames "pkg-b/" root))
         (zip-a (make-zip
                  root (write-source-fixture
                         src-a '(("a.txt" . "a content")))
                  "a.zip"))
         (zip-b (make-zip
                  root (write-source-fixture
                         src-b '(("b.txt" . "b content")))
                  "b.zip"))
         (url-a (http-serve-once zip-a))
         (url-b (http-serve-once zip-b))
         (opts-a (download-install-options proj url-a "a")))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (ensure-directories-exist proj)
          (package:install-package opts-a)
          (package:install-package
            (list* :package-dependency (list "a")
                   (download-install-options proj url-b "b")))
          (let* ((opts-dry (append (list :cascade t :dry-run t) opts-a))
                 (removed (package:remove-package opts-dry)))
            (is = 2 (length removed))
            (is string= "b" (getf (first removed) :name))
            (is string= "a" (getf (second removed) :name))
            ;; Both packages remain installed and their files remain.
            (true (not (null (package:get-package-info opts-dry))))
            (true (not (null
                         (package:get-package-info
                           (install-options proj "b")))))
            (true (uiop:file-exists-p (merge-pathnames "a.txt" proj)))
            (true (uiop:file-exists-p (merge-pathnames "b.txt" proj)))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test remove-package-backs-up-config-files
  :parent nil
  "remove-package backs up an installed package's config files on
   disk (as name.version.backup) and deletes its normal files."
  (let* ((root (temporary-dir "zick-remove-cfg"))
         (proj (project-dir root))
         (src (source-dir root))
         (zip-path (make-zip
                     root (write-source-fixture
                            src '(("app.txt" . "app content")
                                  ("conf.txt" . "config content")))
                     "pkg.zip"))
         (url (http-serve-once zip-path))
         (opts (download-install-options proj url "a"
                                         :metadata (config-metadata))))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (ensure-directories-exist proj)
          (package:install-package opts)
          ;; Both files are on disk after the download install.
          (true (uiop:file-exists-p
                  (merge-pathnames "app.txt" proj)))
          (true (uiop:file-exists-p
                  (merge-pathnames "conf.txt" proj)))
          (package:remove-package opts)
          ;; The config file was backed up, the normal file deleted.
          (true (not (uiop:file-exists-p
                       (merge-pathnames "conf.txt" proj))))
          (is string= "config content"
              (read-text-file
                (merge-pathnames "conf.txt.a.0.1.0.backup" proj)))
          (true (not (uiop:file-exists-p
                       (merge-pathnames "app.txt" proj)))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

;;; verify-package-files

(define-test verify-package-files-errors-when-missing
  :parent nil
  "verify-package-files signals when the package is not installed."
  (let* ((root (temporary-dir "zick-verify-miss"))
         (opts (install-options root "nope")))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (true (handler-case
                    (progn (package:verify-package-files opts) nil)
                  (error (e)
                    (search "Could not extract file information"
                            (princ-to-string e))))))
      (uiop:delete-directory-tree root :validate t))))

(define-test verify-package-files-reports-mismatches
  :parent nil
  "verify-package-files omits :correct results and groups the rest by
   result keyword."
  (let* ((root (temporary-dir "zick-verify"))
         (proj (project-dir root))
         (db-dir (merge-pathnames ".zick-db/" root))
         (store (db:add-package
                  (db:empty-store)
                  (list :package-name "a"
                        :package-version "0.1.0"
                        :package-location "loc"
                        :package-metadata nil)
                  (list (list :path "a.txt" :size 5
                              :is-directory nil
                              :checksum *sha256-hello*))
                  nil))
         (opts (list :package-name "a"
                     :db-connection-string
                     (uiop:native-namestring db-dir)
                     :root-path proj)))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (ensure-directories-exist proj)
          (write-text-file (merge-pathnames "a.txt" proj) "hello")
          (db:save-store (merge-pathnames "packages.nrdl" db-dir)
                         store)
          ;; Everything correct: no groups.
          (is equal '()
              (package:verify-package-files opts))
          ;; Corrupt the file (same size): checksum group.
          (write-text-file
            (merge-pathnames "a.txt" proj)
            "HELLO")
          (let* ((groups (package:verify-package-files opts))
                 (group (car groups)))
            (is = 1 (length groups))
            (is eq :checksum-discrepancy (car group))
            (is string= "a.txt"
                (getf (first (cdr group)) :path))))
      (uiop:delete-directory-tree root :validate t))))

;;; More linearization cases

(defun diamond (node)
  "A diamond graph: c depends on a and b, and both depend on d."
  (cdr (assoc node '((:c . (:a :b))
                     (:a . (:d))
                     (:b . (:d))
                     (:d)))))

(defun self-loop (node)
  "A graph where a depends on itself."
  (cdr (assoc node '((:a . (:a))))))

(define-test linearize-diamond
  :parent nil
  "linearize visits a shared dependency exactly once, sinks first."
  (is equal '(:d :a :b :c) (package:linearize #'diamond :c)))

(define-test linearize-unknown-node
  :parent nil
  "linearize of a node with no neighbors is that node alone."
  (is equal '(:zzz) (package:linearize #'no-edges :zzz)))

(define-test linearize-self-loop
  :parent nil
  "linearize resolves a self-loop by listing the node once."
  (is equal '(:a) (package:linearize #'self-loop :a)))

(define-test reachable-nodes-basics
  :parent nil
  "reachable-nodes collects every node reachable from the start."
  (let ((rnodes (package:reachable-nodes #'basic :c '() '())))
    (is = 3 (length rnodes))
    (true (member :a rnodes :test #'string=))
    (true (member :b rnodes :test #'string=))
    (true (member :c rnodes :test #'string=))))

(define-test reachable-nodes-respects-ignore
  :parent nil
  "reachable-nodes skips the nodes listed in IGNORE."
  (let ((rnodes (package:reachable-nodes #'fighter :c '() '(:u :v :w :x))))
    ;; :u's whole subtree (u, v, w, x) is gone; the rest remains.
    (true (null (member :u rnodes :test #'string=)))
    (true (null (member :v rnodes :test #'string=)))
    (is = 5 (length rnodes))
    (true (member :a rnodes :test #'string=))
    (true (member :b rnodes :test #'string=))
    (true (member :c rnodes :test #'string=))
    (true (member :d rnodes :test #'string=))
    (true (member :e rnodes :test #'string=))))

(define-test sinks-basics
  :parent nil
  "sinks returns the nodes with no neighbors outside IGNORE."
  (is equal '(:a) (package:sinks '(:c :b :a) #'basic '()))
  (is equal '(:a :e)
      (package:sinks '(:c :b :a :e) #'basic '()))
  (is equal '(:a)
      (package:sinks '(:c :b :a) #'basic '(:b))))

;;; File conflicts

(define-test package-file-conflicts-clean
  :parent nil
  "package-file-conflicts finds nothing when files are unowned."
  (let ((store (store-with-files "a" "0.1.0" nil)))
    (is equal '()
        (package:package-file-conflicts
          store "b"
          (list (list :path "fresh.txt" :is-directory nil)
                (list :path "dir/" :is-directory t))))))

(define-test package-file-conflicts-reports-owner
  :parent nil
  "package-file-conflicts names the package that owns a clashing
   file, but not files the installing package already owns."
  (let ((store (store-with-files
                 "a" "0.1.0"
                 (list (list :path "shared.txt" :size 1
                             :is-directory nil :checksum "c")))))
    (let ((conflicts
            (package:package-file-conflicts
              store "b"
              (list (list :path "shared.txt" :is-directory nil)))))
      (is = 1 (length conflicts))
      (is string= "a" (getf (first conflicts) :package))
      (is string= "shared.txt"
          (getf (first conflicts) :path)))
    ;; A package's own files are not conflicts.
    (is equal '()
        (package:package-file-conflicts
          store "a"
          (list (list :path "shared.txt" :is-directory nil))))))

;;; More config-fate combinations

(define-test decide-config-fate-more
  :parent nil
  "decide-config-fate covers the remaining combinations."
  ;; Unchanged file present on disk: nothing to do.
  (is eq :do-nothing
      (package:decide-config-fate "old" "current" "old"))
  ;; Same checksum everywhere: install is a no-op.
  (is eq :install (package:decide-config-fate "x" "x" "x"))
  ;; No old record, file present on disk: put the new one aside.
  (is eq :put-aside (package:decide-config-fate nil "cur" "new"))
  ;; File absent on disk: install regardless of old record.
  (is eq :install (package:decide-config-fate "old" nil "new")))

;;; install-package dependency handling

(define-test install-package-unmet-dependency
  :parent nil
  "install-package signals when a dependency is not installed."
  (let* ((root (temporary-dir "zick-unmet"))
         (opts (install-options root "b"
                                :dependencies (list "missing"))))
    (unwind-protect
        (progn
          (ensure-directories-exist root)
          (true (handler-case
                    (progn
                      (package:install-package opts)
                      nil)
                  (error (e)
                    (search "unmet" (princ-to-string e))))))
      (uiop:delete-directory-tree root :validate t))))
