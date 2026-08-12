---
name: new-project
sub-of: djha-skin-common-lisp
description: How to set up a new project in Common Lisp, Dan Haskin style.
---
# `djha-skin` Common Lisp - New Project

This subskill documents how to set up a new project in Common Lisp, Dan Haskin
style.

o# Inputs

This skill takes two values: the new name of the repository and whether or not
it is a command line tool or a library.

## Steps

1. Create the repository by running `gh repo create --public
   djha-skin/<name-of-the-repository>`. The following steps all take place
   within the folder created by this step.


2. Run `ocicl setup` if you haven't already, then `ocicl install` to install
   dependencies as they are added to the `ocicl.csv` file.

3. Create an file named `com.djhaskin.<name-of-the-repository>` for ASDF. Name
   the project `"com.djhaskin.<name-of-the-repository>"`. Use strings, not
   keywords, when naming systems. An example ASD file follows. If you use it as
   a template, omit the explanatory comments in it.


```
(defsystem "com.djhaskin.<name-of-the-repository>"
  :version "0.1.0"
  :author "Daniel Jay Haskin"
  :license "MIT"
  :depends-on (
              ;; List dependencies here
               )
  :components ((:module "src"
          :components
          ((:file "file1")
           (:file "file2")
           (:file "file3")
           ;; ...
           (:file "main")))) ; This last refers to the file `src/main.lisp`
  :description "Description goes here."
  :in-order-to ((test-op (test-op "com.djhaskin.<name-of-the-repository>/tests"))))

(defsystem "com.djhaskin.rssm/tests"
  :version "0.1.0"
  :author "Daniel Jay Haskin"
  :license "MIT"
  :depends-on (
               "com.djhaskin.rssm"
               "parachute"
               )
  :components ((:module "tests"
                :components
                ((:file "testfile1")
                 (:file "testfile2")
                 ;; ...
                 (:file "main")))) ; This refers to the file `tests/main.lisp`
  :description "Test system for <Name Of The Repository>"
 :perform (asdf:test-op (op c)
                    (uiop:symbol-call :parachute :test '#:com.djhaskin.rssm/tests)
                    (uiop:symbol-call :parachute :test '#:com.djhaskin.rssm/tests/testfile1)
                    (uiop:symbol-call :parachute :test '#:com.djhaskin.rssm/tests/testfile2)))

```

4. Create a directory called `src` and one called `tests`.

5. Create `src/main.lisp`. It should at least have the following content, or
   look like the following example:


```

;;;; src/main.lisp
;;;;
;;;; Description of what the main file contains.

(defpackage #:com.djhaskin.<name-of-the-repository>
  (:use #:cl)
  (:import-from #:com.djhaskin.<name-of-the-repository>/file1)
  (:import-from #:com.djhaskin.<name-of-the-repository>/file2)
  (:import-from #:com.djhaskin.<name-of-the-repository>/file3)
  (:import-from #:some-dependency)
  (:local-nicknames (#:small-nick #:some-long-dependency-name)
                    (#:file1 #:com.djhaskin.<name-of-the-repository)/file1)
                    (#:file1 #:com.djhaskin.<name-of-the-repository)/file2))
  (:export 
    ;; Export stuff here
  ))

(in-package #:com.djhaskin.<name-of-the-repository>)

;;; defun and defparameter definitions ...
```

6. Create `tests/main.lisp`. It should at least have the following content, or
   look like the following example:

```
;;;; tests/main.lisp
;;;;
;;;; Unit tests for RSSM packages.

(defpackage #:com.djhaskin.rssm/tests
  (:use #:cl)
  (:import-from
    #:org.shirakumo.parachute
    #:define-test
    #:true
    #:false
    #:fail
    #:is
    #:isnt
    #:finish
    #:test)
  (:import-from
    #:com.djhaskin.rssm
    #:execute-program
    #:convert-command
    #:main)
  (:local-nicknames
    (#:parachute #:org.shirakumo.parachute)
    (#:<name-of-the-repository> #:com.djhaskin.<name-of-the-repository>)))

(in-package #:com.djhaskin.rssm/tests)

;;; Test the execute-program function with convert subcommand

(define-test an-example-test
  :parent nil
  (true (some-test-or-other))
  ;; ...
  )
```

7. Read the style guide subskill and notice how they fit with the above
   examples.

8. IF the repository is for a command line tool, continue these steps by
   following the instructions found in the [CLIFF Command Line
   Tool](subskills/cliff-command-line-tool.md) subskill.

9. Fill out the code as necessary until you can run `(asdf:test-system
   "com.djhaskin.<name-of-system>")` using `swanky`.
