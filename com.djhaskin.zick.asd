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
                ((:file "main"))))
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
                ((:file "main"))))
  :description "Test system for zick."
  :perform (asdf:test-op (op c)
                    (uiop:symbol-call :parachute :test
                      '#:com.djhaskin.zick/tests/main)))
