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
               "cl-json"
               ;; Archive handling and crypto
               "zippy"
               "ironclad"
               )
  :components ((:module "src"
                :components
                ((:file "fs")
                 (:file "db")
                 (:file "session")
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
               )
  :components ((:module "tests"
                :components
                ((:file "main")
                 (:file "fs")
                 (:file "db")
                 (:file "session"))))
  :description "Test system for zick."
  :perform (asdf:test-op (op c)
                    (uiop:symbol-call :parachute :test
                      (list
                        '#:com.djhaskin.zick/tests/main
                        '#:com.djhaskin.zick/tests/fs
                        '#:com.djhaskin.zick/tests/db
                        '#:com.djhaskin.zick/tests/session))))
