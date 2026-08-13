;;;; scripts/ci-build.lisp
;;;;
;;;; Build the zick executable with a bare SBCL — no Roswell — for the CI
;;;; release builds (Linux/macOS/Windows).  The normal development build is
;;;; ./scripts/build (roswell); this script exists so CI can build with only
;;;; an SBCL installation.
;;;;
;;;; Invoke from the repository root with the runtime options baked in, e.g.:
;;;;
;;;;   sbcl --dynamic-space-size 4096 --control-stack-size 32 \
;;;;        --non-interactive --load scripts/ci-build.lisp
;;;;
;;;; save-lisp-and-die records the current runtime options
;;;; (:save-runtime-options t), so the produced executable starts with the
;;;; large heap and control stack zick needs for big repository resolutions,
;;;; exactly like the roswell build bakes them in.
;;;;
;;;; The result is ./zick (zick.exe on Windows).

(require :asdf)

;;; Make ocicl-installed systems visible to ASDF.  The ocicl runtime
;;; (installed by `ocicl setup`) registers an ASDF system-definition search
;;; function that resolves the systems named in ocicl.csv to the directories
;;; `ocicl install` downloaded them into.  Roswell loads this automatically
;;; via ~/.roswell/init.lisp; here we load it explicitly so a bare SBCL can
;;; find the dependencies too.
;;;
;;; The runtime lives in ocicl's data directory, computed the same way ocicl
;;; itself computes it (its get-ocicl-dir): the XDG data home plus an "ocicl"
;;; subdirectory.  That is ~/.local/share/ocicl on Unix and
;;; %LOCALAPPDATA%\ocicl on Windows, so one code path covers every platform.
(let* ((ocicl-dir (merge-pathnames
                   (make-pathname :directory '(:relative "ocicl"))
                   (uiop:xdg-data-home)))
       (runtime (merge-pathnames "ocicl-runtime.lisp" ocicl-dir)))
  (if (probe-file runtime)
      (progn
        (format *error-output* ";; ci-build: loading ocicl runtime ~A~%" runtime)
        (load runtime))
      (format *error-output*
              ";; ci-build: no ocicl runtime at ~A; run `ocicl setup`~%"
              runtime)))

;;; Make the repository's own .asd files findable.  ASDF's default source
;;; registry includes the current directory on Unix, but not reliably on
;;; Windows, so register it explicitly (the same snippet `ocicl setup`
;;; suggests putting in your startup file).  Without this, the ocicl
;;; system-definition searcher gets consulted for our own systems and tries
;;; to `ocicl install` them.
(asdf:initialize-source-registry
  (list :source-registry
        (list :directory (uiop:getcwd))
        :inherit-configuration))

(asdf:load-asd (merge-pathnames "com.djhaskin.zick.asd" (uiop:getcwd)))
(asdf:load-system :com.djhaskin.zick)

(sb-ext:save-lisp-and-die
  "zick"
  :executable t
  :save-runtime-options t
  :toplevel (lambda ()
              (sb-ext:exit
                :code
                (nth-value 0 (com.djhaskin.zick:main)))))
