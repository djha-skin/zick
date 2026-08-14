;;;; tests/main.lisp
;;;;
;;;; Integration tests for the zick command-line interface in
;;;; src/main.lisp: exercise `main` against real temporary projects
;;;; (with a throwaway HTTP server for the download path), covering
;;;; init/add/info/files/verify/remove/dependers/dependees, the verify
;;;; exit codes 3 and 4, missing-argument errors, JSON package
;;;; metadata, and the deprecated `.zic-db` marking-file fallback.

(defpackage #:com.djhaskin.zick/tests/main
  (:use #:cl)
  (:import-from #:com.djhaskin.zick
    #:main)
  (:import-from #:com.djhaskin.zick/db
    #:save-store)
  (:import-from #:com.djhaskin.zick/lockfile
    #:make-lockfile-package
    #:write-lockfile)
  (:import-from #:com.djhaskin.zick/tests/package
    #:http-serve-once
    #:http-serve-once-auth
    #:make-zip
    #:project-dir
    #:read-text-file
    #:source-dir
    #:store-with-files
    #:temporary-dir
    #:write-source-fixture
    #:write-text-file)
  (:import-from #:fset)
  (:import-from #:uiop)
  (:import-from #:parachute
    #:define-test
    #:is
    #:true))

(in-package #:com.djhaskin.zick/tests/main)

;;; Helpers

(defun project (root)
  "Ensure the project directory under ROOT exists and return it."
  (let ((proj (project-dir root)))
    (ensure-directories-exist proj)
    proj))

(defun temp-project (prefix)
  "A fresh temporary root and its project directory (created)."
  (let* ((root (temporary-dir prefix))
         (proj (project root)))
    (values root proj)))

(defun run-captured (thunk)
  "Run THUNK with *standard-output* and *error-output* redirected to
   a string stream, returning (values exit-code output)."
  (let ((out (make-string-output-stream)))
    (let ((*standard-output* out)
          (*error-output* out))
      (values (funcall thunk) (get-output-stream-string out)))))

(defun cli (dir &rest argv)
  "Run zick with ARGV against the project at DIR, returning the exit
   code.  The directory is passed without a trailing slash, as a
   user would type it (setup must handle it as a directory)."
  (apply #'main "-d"
         (string-right-trim "/" (uiop:native-namestring dir))
         argv))

(defun cli-captured (dir &rest argv)
  "Run zick with ARGV against the project at DIR, returning (values
   exit-code output)."
  (run-captured (lambda () (apply #'cli dir argv))))

;;; Smoke tests

(define-test system-package-exists
  :parent nil
  "The com.djhaskin.zick package is defined when the system loads."
  (true (not (null (find-package :com.djhaskin.zick)))))

(define-test help-exits-successfully
  :parent nil
  "The CLIFF help page exits successfully."
  (is = 0 (main "help")))

(define-test unknown-subcommand-exits-with-usage-error
  :parent nil
  "An unknown subcommand exits with CLIFF's usage error code (64)."
  (is = 64 (main "no-such-subcommand")))

;;; Download authorizations parsing

(define-test json-download-authorizations-parses-records
  :parent nil
  "json-download-authorizations-to-table interns host keys and
   converts each record to fs:download's keyword-keyed shape, with
   :TYPE kept as a string and :HEADERS as an alist."
  (let* ((json (concatenate
                 'string
                 "{\"example.com\": {\"type\": \"basic\", "
                 "\"username\": \"mode\", \"password\": \"code\"}, "
                 "\"api.example.com\": {\"type\": \"header\", "
                 "\"headers\": {\"X-Key\": \"value\"}}}"))
         (table
           (com.djhaskin.zick::json-download-authorizations-to-table
             json)))
    ;; Host keys are interned as upcased keywords.
    (is string= "mode"
        (gethash :username
                 (gethash :|EXAMPLE.COM| table)))
    (is string= "basic"
        (gethash :type (gethash :|EXAMPLE.COM| table)))
    ;; :headers is an alist of conses, as dexador expects.
    (is equal '(("X-Key" . "value"))
        (gethash :headers
                 (gethash :|API.EXAMPLE.COM| table)))))

;;; init

(define-test init-creates-store
  :parent nil
  "zick init creates the .zick-db store document at the start
   directory."
  (multiple-value-bind (root proj) (temp-project "zick-cli-init")
    (unwind-protect
        (progn
          (is = 0 (cli proj "init"))
          (true (uiop:file-exists-p
                  (merge-pathnames ".zick-db/packages.nrdl" proj))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

;;; declarative lockfiles

(define-test freeze-writes-declarative-lockfile
  :parent nil
  "freeze writes a deterministic NRDL lockfile from installed packages."
  (multiple-value-bind (root proj) (temp-project "zick-cli-freeze")
    (unwind-protect
        (progn
          (is = 0 (cli proj "init"))
          (is = 0 (cli proj "add" "-k" "z" "-V" "1.0"
                       "-l" "https://example.com/z.zip" "-W"))
          (is = 0 (cli proj "add" "-k" "a" "-V" "2.0"
                       "-l" "https://example.com/a.zip" "-W" "-u" "z"))
          (is = 0 (cli proj "freeze"))
          (let ((lockfile (read-text-file
                           (merge-pathnames "zick.lock.nrdl" proj))))
            (true (search "version 1" lockfile))
            (true (< (search "name \"a\"" lockfile)
                     (search "name \"z\"" lockfile)))
            (true (search "dependencies [" lockfile))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test sync-downloads-lockfile-in-dependency-order
  :parent nil
  "sync downloads missing lockfile packages after ordering dependencies."
  (multiple-value-bind (root proj) (temp-project "zick-cli-sync")
    (unwind-protect
        (let* ((src-a (merge-pathnames "a-src/" root))
               (src-b (merge-pathnames "b-src/" root))
               (zip-a (make-zip root
                                (write-source-fixture src-a
                                                       '(("a.txt" . "a")))
                                "a.zip"))
               (zip-b (make-zip root
                                (write-source-fixture src-b
                                                       '(("b.txt" . "b")))
                                "b.zip"))
               (url-a (http-serve-once zip-a))
               (url-b (http-serve-once zip-b)))
          (is = 0 (cli proj "init"))
          ;; Write b before a to prove sync follows dependency edges,
          ;; rather than trusting lockfile order.
          (write-lockfile
           (merge-pathnames "zick.lock.nrdl" proj)
           (list
            (make-lockfile-package
             :name "b" :version "1.0" :location url-b
             :dependencies (fset:convert 'fset:seq (list "a")))
            (make-lockfile-package
             :name "a" :version "1.0" :location url-a)))
          (is = 0 (cli proj "sync"))
          (true (uiop:file-exists-p (merge-pathnames "a.txt" proj)))
          (true (uiop:file-exists-p (merge-pathnames "b.txt" proj)))
          ;; A second synchronization is a no-op and does not attempt
          ;; to fetch the one-shot fixture URLs again.
          (multiple-value-bind (exit out) (cli-captured proj "sync")
            (is = 0 exit)
            (true (search "skipped-packages" out))
            (true (search "\"a\"" out))
            (true (search "\"b\"" out)))
          (multiple-value-bind (exit out) (cli-captured proj "list")
            (is = 0 exit)
            (true (search "name \"a\"" out))
            (true (search "name \"b\"" out))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

;;; add and queries without download

(define-test add-records-package-without-download
  :parent nil
  "zick add -W records a package in the store, and info shows it."
  (multiple-value-bind (root proj) (temp-project "zick-cli-add")
    (unwind-protect
        (progn
          (is = 0 (cli proj "init"))
          (is = 0 (cli proj "add" "-k" "a" "-V" "0.1.0"
                       "-l" "https://example.com/a.zip" "-W"))
          (multiple-value-bind (exit out)
                               (cli-captured proj "info" "-k" "a")
            (is = 0 exit)
            (true (search "\"a\"" out))
            (true (search "\"0.1.0\"" out))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test add-with-dependency-drives-dependers-and-dependees
  :parent nil
  "A package added with -u shows up in the dependees of its
   dependency and the dependers of the dependent."
  (multiple-value-bind (root proj) (temp-project "zick-cli-deps")
    (unwind-protect
        (progn
          (is = 0 (cli proj "init"))
          (is = 0 (cli proj "add" "-k" "a" "-V" "0.1.0"
                       "-l" "https://example.com/a.zip" "-W"))
          (is = 0 (cli proj "add" "-k" "b" "-V" "0.1.0"
                       "-l" "https://example.com/b.zip" "-W"
                       "-u" "a"))
          (multiple-value-bind (exit out)
                               (cli-captured proj "dependees" "-k" "b")
            (is = 0 exit)
            (true (search "\"a\"" out)))
          (multiple-value-bind (exit out)
                               (cli-captured proj "dependers" "-k" "a")
            (is = 0 exit)
            (true (search "\"b\"" out))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test orphans-reports-packages-nothing-depends-on
  :parent nil
  "zick orphans lists the installed packages that nothing depends
   on; installing a package that depends on another and then removing
   the depender leaves the dependency reported.  An empty set of
   orphans renders as `[]`, not `false` (NRDL maps nil to false)."
  (multiple-value-bind (root proj) (temp-project "zick-cli-orphans")
    (unwind-protect
        (progn
          (is = 0 (cli proj "init"))
          ;; No packages at all: the orphan list is empty, and must
          ;; render as `[]` rather than `false`.
          (multiple-value-bind (exit out)
                               (cli-captured proj "orphans")
            (is = 0 exit)
            (true (search "orphaned-packages [" out))
            (true (null (search "orphaned-packages false" out))))
          ;; A standalone install is orphaned (nothing depends on it).
          (is = 0 (cli proj "add" "-k" "a" "-V" "0.1.0"
                       "-l" "https://example.com/a.zip" "-W"))
          (multiple-value-bind (exit out)
                               (cli-captured proj "orphans")
            (is = 0 exit)
            (true (search "name \"a\"" out)))
          ;; Once b depends on a, a is no longer orphaned; b is.
          (is = 0 (cli proj "add" "-k" "b" "-V" "0.1.0"
                       "-l" "https://example.com/b.zip" "-W"
                       "-u" "a"))
          (multiple-value-bind (exit out)
                               (cli-captured proj "orphans")
            (is = 0 exit)
            (true (search "name \"b\"" out))
            (true (not (search "name \"a\"" out))))
          ;; Removing the depender orphans the dependency again.
          (is = 0 (cli proj "remove" "-k" "b"))
          (multiple-value-bind (exit out)
                               (cli-captured proj "orphans")
            (is = 0 exit)
            (true (search "name \"a\"" out))
            (true (not (search "name \"b\"" out)))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test list-reports-installed-packages
  :parent nil
  "zick list prints every installed package with its version, sorted
   by name; an empty database prints nothing and exits 0."
  (multiple-value-bind (root proj) (temp-project "zick-cli-list")
    (unwind-protect
        (progn
          (is = 0 (cli proj "init"))
          ;; An empty database prints nothing and exits 0.
          (multiple-value-bind (exit out)
                               (cli-captured proj "list")
            (is = 0 exit)
            (is string= "" out))
          (is = 0 (cli proj "add" "-k" "b" "-V" "0.2.0"
                       "-l" "https://example.com/b.zip" "-W"))
          (is = 0 (cli proj "add" "-k" "a" "-V" "0.1.0"
                       "-l" "https://example.com/a.zip" "-W"))
          (multiple-value-bind (exit out)
                               (cli-captured proj "list")
            (is = 0 exit)
            (true (search "name \"a\"" out))
            (true (search "version \"0.1.0\"" out))
            (true (search "name \"b\"" out))
            (true (search "version \"0.2.0\"" out))
            (true (< (search "name \"a\"" out)
                     (search "name \"b\"" out)))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

;;; Missing-argument errors

(define-test query-subcommands-require-package-name
  :parent nil
  "files/info/remove/verify/dependers/dependees exit 64 without -k."
  (multiple-value-bind (root proj) (temp-project "zick-cli-missing")
    (unwind-protect
        (dolist (cmd '("files" "info" "remove" "verify"
                       "dependers" "dependees"))
          (is = 64 (cli proj cmd)))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test add-missing-arguments-signals
  :parent nil
  "zick add without name/version/location exits non-zero and names
   the missing requirement."
  (multiple-value-bind (root proj) (temp-project "zick-cli-addmissing")
    (unwind-protect
        (progn
          (is = 0 (cli proj "init"))
          (multiple-value-bind (exit out)
                               (cli-captured proj "add")
            (true (plusp exit))
            (true (search "must all be given" out))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test add-with-unmet-dependency-signals
  :parent nil
  "zick add -u naming an uninstalled package exits non-zero and
   reports the unmet dependency."
  (multiple-value-bind (root proj) (temp-project "zick-cli-unmet")
    (unwind-protect
        (progn
          (is = 0 (cli proj "init"))
          (multiple-value-bind (exit out)
                               (cli-captured proj "add" "-k" "a" "-V" "0.1.0"
                                             "-l" "https://example.com/a.zip"
                                             "-u" "ghost")
            (true (plusp exit))
            (true (search "unmet" out))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

;;; Download, files, and verify

(define-test add-downloads-unpacks-and-verifies
  :parent nil
  "zick add downloads and unpacks a package archive; files lists its
   files; verify exits 0 when correct, 4 after a file is tampered
   with, and 3 for a package that is not installed."
  (let* ((root (temporary-dir "zick-cli-download"))
         (proj (project root))
         (src (source-dir root))
         (zip-path (make-zip
                     root (write-source-fixture
                            src '(("app.txt" . "app content")))
                     "pkg.zip"))
         (url (http-serve-once zip-path)))
    (unwind-protect
        (progn
          (is = 0 (cli proj "init"))
          (is = 0 (cli proj "add" "-k" "a" "-V" "0.1.0" "-l" url))
          (true (uiop:file-exists-p (merge-pathnames "app.txt" proj)))
          (is string= "app content"
              (read-text-file (merge-pathnames "app.txt" proj)))
          (multiple-value-bind (exit out)
                               (cli-captured proj "files" "-k" "a")
            (is = 0 exit)
            (true (search "app.txt" out)))
          (is = 0 (cli proj "verify" "-k" "a"))
          (write-text-file (merge-pathnames "app.txt" proj) "tampered")
          (is = 4 (cli proj "verify" "-k" "a"))
          (is = 3 (cli proj "verify" "-k" "ghost")))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test verify-all-reports-all-package-failures
  :parent nil
  "verify --all handles an empty store, verifies every package, and
   reports failures grouped by package."
  (let* ((root (temporary-dir "zick-cli-verify-all"))
         (proj (project root))
         (src-a (merge-pathnames "pkg-a/" root))
         (src-b (merge-pathnames "pkg-b/" root))
         (zip-a (make-zip
                  root (write-source-fixture src-a
                                              '(("a.txt" . "a content")))
                  "a.zip"))
         (zip-b (make-zip
                  root (write-source-fixture src-b
                                              '(("b.txt" . "b content")))
                  "b.zip"))
         (url-a (http-serve-once zip-a))
         (url-b (http-serve-once zip-b)))
    (unwind-protect
        (progn
          (is = 0 (cli proj "init"))
          (multiple-value-bind (exit out)
                               (cli-captured proj "verify" "--all")
            (is = 0 exit)
            (true (search "result packages-found" out))
            (true (search "verification-results [" out)))
          (is = 0 (cli proj "add" "-k" "a" "-V" "1.0" "-l" url-a))
          (is = 0 (cli proj "add" "-k" "b" "-V" "1.0" "-l" url-b))
          (write-text-file (merge-pathnames "a.txt" proj) "tampered")
          (multiple-value-bind (exit out)
                               (cli-captured proj "verify" "--all")
            (is = 4 exit)
            (true (search "status verification-failed" out))
            (true (search "package \"a\"" out))
            (true (search "size-discrepancy" out)))
          (write-text-file (merge-pathnames "a.txt" proj) "a content")
          (is = 0 (cli proj "verify" "--all")))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test add-with-json-download-authorizations
  :parent nil
  "zick add --json-download-authorizations supplies basic auth to the
   HTTP client; without it, downloading from an auth-protected server
   fails."
  (let* ((root (temporary-dir "zick-cli-auth"))
         (proj (project root))
         (src (source-dir root))
         (zip-path (make-zip
                     root (write-source-fixture
                            src '(("app.txt" . "app content")))
                     "pkg.zip"))
         (url (http-serve-once-auth zip-path :connections 2))
         (auth-json
           (concatenate
             'string
             "{\"127.0.0.1\": {\"type\": \"basic\", "
             "\"username\": \"mode\", \"password\": \"code\"}}")))
    (unwind-protect
        (progn
          (is = 0 (cli proj "init"))
          ;; Without authorizations the download is refused.
          (multiple-value-bind (exit out)
                               (cli-captured proj "add" "-k" "a"
                                             "-V" "0.1.0" "-l" url)
            (true (plusp exit))
            (true (search "401" out)))
          ;; With --json-download-authorizations it succeeds and the
          ;; archive is unpacked.
          (is = 0 (cli proj "add" "-k" "a" "-V" "0.1.0" "-l" url
                       "--json-download-authorizations" auth-json))
          (true (uiop:file-exists-p (merge-pathnames "app.txt" proj)))
          (is string= "app content"
              (read-text-file (merge-pathnames "app.txt" proj))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test add-with-json-metadata-marks-config-files
  :parent nil
  "zick add -m parses the JSON metadata; files declared as config
   files there are recorded as such (deleting one fails
   verification)."
  (let* ((root (temporary-dir "zick-cli-meta"))
         (proj (project root))
         (src (source-dir root))
         (zip-path (make-zip
                     root (write-source-fixture
                            src '(("app.txt" . "app content")
                                  ("conf.txt" . "config content")))
                     "pkg.zip"))
         (url (http-serve-once zip-path)))
    (unwind-protect
        (progn
          (is = 0 (cli proj "init"))
          (is = 0 (cli proj "add" "-k" "a" "-V" "0.1.0" "-l" url
                       "-m" "{\"zick\":{\"config-files\":[\"conf.txt\"]}}"))
          ;; The JSON keys survive keywordization: conf.txt is recorded
          ;; as a config file, app.txt as a normal file.
          (multiple-value-bind (exit out)
                               (cli-captured proj "files" "-k" "a")
            (is = 0 exit)
            (true (search "class config-file" out))
            (true (search "class normal-file" out)))
          (is = 0 (cli proj "verify" "-k" "a"))
          (uiop:delete-file-if-exists (merge-pathnames "conf.txt" proj))
          (is = 4 (cli proj "verify" "-k" "a")))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test json-metadata-keywordizes-nrdl-keys
  :parent nil
  "json-metadata-to-fset normalizes NRDL's case-preserved keyword
   keys (:|zick|) to the uppercase keywords (:ZICK) that zick-paths
   looks up."
  (let ((metadata
          (com.djhaskin.zick::json-metadata-to-fset
            "{\"zick\":{\"config-files\":[\"conf.txt\"]}}")))
    (is = 1 (fset:size (com.djhaskin.zick/db:zick-paths
                         metadata :config-files)))
    (is string= "conf.txt"
        (fset:first (com.djhaskin.zick/db:zick-paths
                      metadata :config-files)))))

(define-test add-refuses-conflicting-install
  :parent nil
  "zick add of a package whose archive owns a file already owned by
   another package fails, naming the file and its owner; the earlier
   package stays intact."
  (let* ((root (temporary-dir "zick-cli-conflict"))
         (proj (project root))
         (src-a (merge-pathnames "pkg-a/" root))
         (src-b (merge-pathnames "pkg-b/" root))
         (zip-a (make-zip
                  root (write-source-fixture
                         src-a '(("app.txt" . "a content")))
                  "a.zip"))
         (zip-b (make-zip
                  root (write-source-fixture
                         src-b '(("app.txt" . "b content")
                                 ("b-only.txt" . "b only")))
                  "b.zip"))
         (url-a (http-serve-once zip-a))
         (url-b (http-serve-once zip-b)))
    (unwind-protect
        (progn
          (is = 0 (cli proj "init"))
          (is = 0 (cli proj "add" "-k" "a" "-V" "0.1.0" "-l" url-a))
          ;; b clashes with a on app.txt: refused, naming file+owner.
          (multiple-value-bind (exit out)
                               (cli-captured proj "add" "-k" "b"
                                             "-V" "0.1.0" "-l" url-b)
            (true (plusp exit))
            (true (search "already present" out))
            (true (search "app.txt (owned by" out)))
          ;; a's file is untouched and a remains installed.
          (is string= "a content"
              (read-text-file (merge-pathnames "app.txt" proj)))
          (is = 0 (cli proj "info" "-k" "a")))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

;;; remove

(define-test remove-then-info-reports-not-found
  :parent nil
  "zick remove deletes a recorded package; a second remove and info
   both report it absent (exit 0 with :not-found)."
  (multiple-value-bind (root proj) (temp-project "zick-cli-remove")
    (unwind-protect
        (progn
          (is = 0 (cli proj "init"))
          (is = 0 (cli proj "add" "-k" "a" "-V" "0.1.0"
                       "-l" "https://example.com/a.zip" "-W"))
          (is = 0 (cli proj "remove" "-k" "a"))
          (is = 0 (cli proj "remove" "-k" "a"))
          (multiple-value-bind (exit out)
                               (cli-captured proj "info" "-k" "a")
            (is = 0 exit)
            (true (search "not-found" out))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test remove-without-cascade-signals
  :parent nil
  "zick remove of a package others depend on exits non-zero without
   -c, naming the dependers."
  (multiple-value-bind (root proj) (temp-project "zick-cli-cascade")
    (unwind-protect
        (progn
          (is = 0 (cli proj "init"))
          (is = 0 (cli proj "add" "-k" "a" "-V" "0.1.0"
                       "-l" "https://example.com/a.zip" "-W"))
          (is = 0 (cli proj "add" "-k" "b" "-V" "0.1.0"
                       "-l" "https://example.com/b.zip" "-W"
                       "-u" "a"))
          (multiple-value-bind (exit out)
                               (cli-captured proj "remove" "-k" "a")
            (true (plusp exit))
            (true (search "depend" out))
            (true (search "cannot remove: b" out))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

(define-test remove-dry-run-leaves-files
  :parent nil
  "zick remove -r reports what would be removed but leaves the
   package, its files, and its record alone."
  (let* ((root (temporary-dir "zick-cli-dryrun"))
         (proj (project root))
         (src (source-dir root))
         (zip-path (make-zip
                     root (write-source-fixture
                            src '(("app.txt" . "app content")))
                     "pkg.zip"))
         (url (http-serve-once zip-path)))
    (unwind-protect
        (progn
          (is = 0 (cli proj "init"))
          (is = 0 (cli proj "add" "-k" "a" "-V" "0.1.0" "-l" url))
          (multiple-value-bind (exit out)
                               (cli-captured proj "remove" "-k" "a" "-r")
            (is = 0 exit)
            (true (search "dry-run true" out))
            (true (search "removed-packages" out)))
          ;; The package record and its file remain.
          (multiple-value-bind (exit out)
                               (cli-captured proj "info" "-k" "a")
            (is = 0 exit)
            (true (search "\"a\"" out)))
          (true (uiop:file-exists-p (merge-pathnames "app.txt" proj))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))

;;; Deprecated marking file

(define-test legacy-zic-db-marking-file-warns-and-works
  :parent nil
  "A project marked with the deprecated .zic-db file is still used,
   with a deprecation warning on stderr."
  (multiple-value-bind (root proj) (temp-project "zick-cli-legacy")
    (unwind-protect
        (progn
          (save-store (merge-pathnames ".zic-db/packages.nrdl" proj)
                      (store-with-files "legacy" "0.1.0" nil))
          (multiple-value-bind (exit out)
                               (cli-captured proj "info" "-k" "legacy")
            (is = 0 exit)
            (true (search "deprecated" out))
            (true (search "\"legacy\"" out))))
      (uiop:delete-directory-tree root :validate t
                                  :if-does-not-exist :ignore))))
