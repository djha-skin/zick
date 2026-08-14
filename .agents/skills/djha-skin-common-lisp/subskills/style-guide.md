---
name: style-guide
sub-of: djha-skin-common-lisp
description: >
  Style points on how to write good Common Lisp code, Dan Haskin
  style.
---

# Style Guide

Please note the following style guidelines:

* We use full-name reverse-DNS semantics to name ASDF systems

* There should at least be a `src/main.lisp` and a `tests/main.lisp` file
  present.

* License is MIT.

* We use the parachute library for tests.

* We call each test package on `(asdf:test-system
  "com.djhaskin.<name-of-the-repository>")`.

* Uninterned keyword symbols are preferred when naming and pulling in
  packages within a `defpackage` form; interned keywords are used as directives
  within `defpackage` (`:use`, `:import-from`, etc.)

* We use full-name, reverse-DNS semantics to name packages, and the `main.lisp`
  file's package should match that of the whole system

* Each file gets its own subpackage

* Each dependency within a `defpackage` form gets its own `(:import-from)`
  statement which doesn't actually list any symbols from that package. This is
  solely to tell ASDF that they are dependencies of this package.

* Local nicknames in `defpackage` and throughout the source are heavily used,
  including to remove all the reverse-DNS prefixes of in-system package
  dependencies

## Naming conventions

* Follow standard Common Lisp naming conventions. In particular, do not carry
  over Clojure or FSet idioms when porting code:

  * No `!` suffix for destructive or side-effecting functions (a Clojure
    convention). Use plain names: `remove-files`, not `remove-files!`.

  * No `?` suffix for predicates. Use the standard Common Lisp `p` or `-p`
    suffix instead: `insecure-p`, `directory-entry-p`.

  * Third-party library symbols keep their own names (e.g. `fset:contains?`),
    even when they use `!` or `?`.

* When porting Clojure code, translate function names to these conventions as
  part of the port, updating all call sites and tests accordingly.

## Files

* Files should all begin with file beginner comment lines, prefixed with four
  semi-colons (`;;;;`).

* Comments above top-level definitions (`defun`, `defparameter`, etc.) hould
  start with three semi-colons (`;;;`).

* Comments on their own line should start with two semi-colons (`;;`).

* Comments sharing a line with code should start with one, or a single
  semi-colon (`;`).

* All the same conventions apply to test code (under the `tests/` folder) as
  main code (under the `src/` folder).

* Parachute within test code `defpackage` forms in particular should have an
  `import-from` but SHOULD name the symbols we use, contrary to the usual
  convention outlined in this guide.

* Only 80 characters per line, please, for any text-based file in the
  repository. Wrap intelligently if you must to follow this rule.

* Use the skill's `fmt.ros` script (not Roswell's `ros fmt`) to format and
  lint Lisp source files:

  ```sh
  ros .agents/skills/djha-skin-common-lisp/scripts/fmt.ros [--check] [files...]
  ```

  It handles consistent indentation automatically (via cl-indentify), strips
  trailing whitespace, and lints line length, comment style, and file headers.
  With no files it discovers `src/**/*.lisp` and `tests/**/*.lisp`. Pass
  `--check` to lint without rewriting. Run it on all source files before
  committing.

* Use `muxxy` with a project-local `clrepl` tmux pane for ALL interactive Lisp
  operations — loading systems, running tests, evaluating forms, and inspecting
  debugger state. Do NOT use one-off `sbcl` or `ros` commands (except `ros
  build` for executables, `ros init` for script scaffolding, and the explicit
  paren-check script). Use `--kind sbcl`, generous `--timeout` and
  `--max-lines` for loads and test suites. If a form enters the debugger,
  investigate briefly, then use its numbered exit restart immediately. Verify
  the pane is back at `* `, not merely `is-repl-ready`; `(abort)` is not a safe
  substitute. See Development Workflow for nested-prompt and multiline-echo
  workarounds.

* Run `lisp-check-parens.ros` on Lisp source files before committing to catch
  unbalanced parentheses. See the [Development Workflow](development-workflow.md)
  tooling section for usage.

* Use **OCICL** for package management, NOT Qlot or Quicklisp (`ql:quickload`).
  OCICL packages systems as OCI-compliant artifacts distributed via container
  registries. Systems are project-local by default.

  * `ocicl install` — install all systems from `ocicl.csv`
  * `ocicl install <system>` — install a specific system
  * `ocicl list <system>` — see available versions
  * `ocicl latest` — update all systems to latest
  * `ocicl setup` — install ocicl-runtime and configure your Lisp init file
  * `ocicl lint <path>` — lint Common Lisp files

  The `ocicl.csv` file in the project root tracks which systems and versions
  are used. Commit it to version control; never commit the `ocicl/` directory
  (which contains downloaded system code).

* No trailing whitespace, ever.

* Keep a changelog in `CHANGELOG.md` in the root folder. For each version bump,
  track what was changed, fixed, and added.
