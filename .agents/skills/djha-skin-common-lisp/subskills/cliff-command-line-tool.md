---
name: cliff-command-line-tool
sub-of: djha-skin-common-lisp
description: >
  How to set up a command line tool application that utilizes the
  CLIFF common lisp library.
---

# CLIFF Command Line Tool

This skill assumes you have already gone through the steps in the
[New Project](subskills/new-project.md) subskill. It picks up after step 8
(eight) of that skill.

## Steps

1. Ensure `cliff` and its dependencies are installed via `qlot`. `cliff` is a
   git repository that should already be present on this machine in
   `~/Code/djha-skin/cliff`. Add it and its dependencies via Qlot.
   NRDL is a dependency of CLIFF. It can be found in `~/Code/djha-skin/nrdl` as
   well.

1. From the root of the repository, run `ros init <name-of-the-repository>.ros`

2. Add an `(:import-from #:com.djhaskin.<name-of-the-repository>)` to the
   `defpackage` in that ros command

3. Rewrite the `main` function in that file to look like this:

```
(defun main (&rest argv)
  (declare (ignorable argv))
  (sb-ext:exit
    :code
      (nth-value
        0
        (com.djhaskin.<name-of-the-repository>:main argv))))
```

4. In `src/main.lisp`, add a `main` function via `defun` and export it. It
   should call `cliff:exeute-program`, like this:

```
(defun main (argv)
  "Main entry point for the RSSM CLI."
      (cliff:execute-program
        "<name-of-the-repository>"
        :cli-arguments argv)
        ;; More arguments as appropriate)))
```