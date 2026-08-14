(defsystem "com.djhaskin.zick"
  :version "0.1.0"
  :author "Daniel Jay Haskin"
  :license "MIT"
  :depends-on (
               ;; Ported sibling systems
               "com.djhaskin.cliff"
               "com.djhaskin.nrdl"
               "com.djhaskin.svers"
               ;; Data structures and utilities
               "fset"
               "alexandria"
               "cl-ppcre"
               "cl-fad"
               ;; Network and serialization
               "dexador"
               "quri"
               ;; Archive handling and crypto
               "zippy"
               "ironclad"
               )
  :components ((:module "src"
                        :components
                        ((:file "fs")
                         (:file "lockfile")
                         (:file "db")
                         (:file "session")
                         (:file "package")
                         (:file "main"))))
  :description "Zip files In Concert: package manager for source-code repos."
  :in-order-to ((test-op (test-op "com.djhaskin.zick/tests"))))

(defsystem "com.djhaskin.zick/tests"
  :version "0.1.0"
  :author "Daniel Jay Haskin"
  :license "MIT"
  :depends-on (
               "com.djhaskin.zick"
               "parachute"
               ;; Throwaway HTTP server for the download-package tests
               "usocket"
               "bordeaux-threads"
               "flexi-streams"
               )
  :components ((:module "tests"
                        :components
                        ((:file "fs")
                         (:file "lockfile")
                         (:file "db")
                         (:file "session")
                         (:file "package")
                         (:file "main"))))
  :description "Test system for zick."
  :perform (asdf:test-op (op c)
                         (uiop:symbol-call :parachute :test
                                           (list
                                             '#:com.djhaskin.zick/tests/main
                                             '#:com.djhaskin.zick/tests/lockfile
                                             '#:com.djhaskin.zick/tests/fs
                                             '#:com.djhaskin.zick/tests/db
                                             '#:com.djhaskin.zick/tests/session
                                             '#:com.djhaskin.zick/tests/package))))
