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
(let ((ocicl-runtime
        (or
         ;; Linux/macOS: ~/.local/share/ocicl/ocicl-runtime.lisp
         (probe-file
          (merge-pathnames ".local/share/ocicl/ocicl-runtime.lisp"
                           (user-homedir-pathname)))
         ;; Windows: %LOCALAPPDATA%\ocicl\ocicl-runtime.lisp
         (let ((local-app-data (uiop:getenv "LOCALAPPDATA")))
           (and local-app-data
                (probe-file
                 (merge-pathnames
                  "ocicl/ocicl-runtime.lisp"
                  (uiop:parse-native-namestring local-app-data))))))))
  (when ocicl-runtime
    (load ocicl-runtime)))

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
