;;;; src/main.lisp
;;;;
;;;; CLI entry point for zick using CLIFF for argument parsing,
;;;; subcommand dispatch, config files, and environment variables.
;;;;
;;;; Ported from zic's src/zic/cli.clj. The subcommands themselves are
;;;; ported by the port-cli bead; this file currently provides the
;;;; package, the version, a default function, and the CLIFF entry.

(defpackage #:com.djhaskin.zick
  (:use #:cl)
  (:import-from #:com.djhaskin.cliff
    #:execute-program)
  (:import-from #:com.djhaskin.nrdl)
  (:import-from #:com.djhaskin.svers)
  (:import-from #:fset)
  (:import-from #:alexandria)
  (:import-from #:asdf
    #:component-version
    #:find-system)
  (:local-nicknames
    (#:cliff #:com.djhaskin.cliff)
    (#:f #:fset))
  (:export
    #:main))

(in-package #:com.djhaskin.zick)

(defparameter *zick-version*
  (component-version (find-system :com.djhaskin.zick))
  "Version of the zick system, read from its ASDF definition.

   Shown on the CLIFF-generated help page.")

(defun default-fn (options)
  "Default function when no subcommand is given.

   Prints a brief usage summary naming the subcommands to be ported.
   Returns a successful status."
  (declare (ignore options))
  (format t "zick: Zip files In Concert~%")
  (format t "A package manager for project-level source code repositories.~%")
  (format t "~%")
  (format t "Subcommands (to be ported):~%")
  (format t "  add         Add a package to the installation~%")
  (format t "  files       List the files owned by a package~%")
  (format t "  info        Show information about a package~%")
  (format t "  init        Initialize the zick database~%")
  (format t "  remove      Remove a package from the installation~%")
  (format t "  dependers   List packages that depend on a package~%")
  (format t "  dependees   List packages a package depends on~%")
  (format t "  verify      Verify the files of a package~%")
  (format t "~%")
  (format t "Run `zick help` for the CLIFF help page.~%")
  (alexandria:alist-hash-table
    `((:status . :successful)
      (:cliff-suppress-output . t))))

(defun main (&rest argv)
  "Main entry point for the zick CLI tool.

   Uses CLIFF's execute-program for argument parsing, config file
   handling, environment variable processing, and subcommand dispatch.
   Returns the process exit code."
  (declare (ignorable argv))
  (nth-value
    0
    (cliff:execute-program
      "zick"
      :version *zick-version*
      :default-function #'default-fn
      :cli-arguments (if argv (coerce argv 'list) t))))
