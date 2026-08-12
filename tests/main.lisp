;;;; tests/main.lisp
;;;;
;;;; Smoke tests for the zick package.

(defpackage #:com.djhaskin.zick/tests/main
  (:use #:cl)
  (:import-from #:com.djhaskin.zick
    #:main)
  (:import-from #:parachute
    #:define-test
    #:is
    #:true))

(in-package #:com.djhaskin.zick/tests/main)

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
