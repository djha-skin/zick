---
name: development-workflow
sub-of: djha-skin-common-lisp
description: >
  Skill that describes a typical development working session in
  Common Lisp, Dan Haskin style.
---

# Development Workflow

These steps assume you have the repository cloned out and that you are in that
folder.

## Steps

1. Ask the user for instructions on what to build.

2. Ask the user several questions, at least five, about specifics of what is
   needed. Try to make sure you're not guessing at features.

3. Write a bunch of beads using the beads MCP server to capture what the user
   said. Upon first start up, remember to check what beads are open and resume
   them if appropriate.

4. Pick up each bead and work it in turn. As you work each bead, heavily employ
   TDD. Check your work often by spinning up subagents to audit both your work,
   your tests, and your commits.

5. Spin up a subagent to validate your commits against the brief in the beads,
   and offer any helpful critiques. Have them point out any critical bugs or how
   the code could break.

6. Address the concerns.

7. For each bead, commit and push work done per the above workflow. Add an entry
   to the changelog as appropriate. Keep a changelog as set forth here:
   https://keepachangelog.com/en/1.1.0/

## Tooling

Bear in mind, we use the following tools:

* **swanky** — Use the `swanky` CLI tool to interact with a swank server, and
  thus the lisp REPL. Expect the user to have already set up that server and
  have it running. Use swanky for ALL Lisp operations:
  loading systems, running tests, editing forms, checking parens, searching
  code. Do NOT use one-off `sbcl` or `ros` commands.

* **OCICL** for package management. Run `ocicl install` to install all systems
  listed in `ocicl.csv`. Systems are downloaded project-locally. Do NOT use
  Qlot (`qlot`) or Quicklisp (`ql:quickload`).

* Roswell. `ros init` to make roswell scripts, `ros build` to build executables.
  Dependencies are resolved via OCICL, not Qlot.

* For testing, run `(asdf:test-system "com.djhaskin.<name-of-the-repository>")`
  using swanky.

## Using swanky

`swanky` is a one-shot CLI: it connects to the running swank server, evaluates
a single form, prints the result, and exits. The user starts the swank server
(e.g. from a `clrepl` prompt with `(swank:create-server :port 4005 :dont-close t)`).
The default port is `4005`.

Basic usage:

```sh
swanky '(+ 1 2)'                        # print result of a form
echo '(* 6 7)' | swanky                 # read form from stdin
swanky -e '(+ 1 2)' -H 10.0.0.1 -p 4005 # explicit host/port
swanky -e '(format t "hi~%")' --show-output  # capture *standard-output* (goes to stderr)
```

### Gotchas (IMPORTANT — read before using)

1. **Fully qualify ALL symbols in the form you send.** The swank server reads
   the request in `SWANK-IO-PACKAGE`, which uses **no** packages (only `nil`,
   `t`, `quote` are available). An unqualified symbol like `+` or `list` gets
   interned as `SWANK-IO-PACKAGE::+` and will be *undefined*. Always write
   `cl:+`, `cl:list`, `cl:format`, `cl:defun`, etc. Symbols with explicit
   package prefixes (`cl:+`, `com.djhaskin.foo:bar`) resolve fine.

2. **The form is evaluated in the buffer package you name** (`-P/--package`,
   default `CL-USER`). Use `-P` to pick the right package so unqualified
   symbols inside your form resolve where you expect.

3. **Errors do not hang.** swanky wraps your form in a `handler-case` so
   ordinary errors (division by zero, undefined function, etc.) come back as
   an error message on stderr with a non-zero exit code — no debugger prompt.
   If a form does enter the debugger anyway (rare: `break`, `invoke-debugger`),
   swanky prints a warning and exits; tell the user to reset the swank server
   if it gets wedged.

4. **Values are printed with `prin1`-style escaping**, so a string result
   comes back quoted: `"foo"`. Multi-value returns are printed as a list of
   printed values from `eval-and-grab-output`.

5. **Startup is fast (~5ms release build)** — safe to call swanky repeatedly
   in loops and scripts, one invocation per form.

6. **stdout vs stderr.** The evaluated form's result goes to stdout. Output
   written with `(format t ...)` goes to stdout by default too, but with
   `--show-output` it is redirected to stderr so the two don't mix. Use
   `--show-output` when the form both prints and returns a value you need to
   capture programmatically.

### Paren checking

Run the `lisp-check-parens.ros` script (see the
[Style Guide](style-guide.md)) before committing Lisp sources:

```sh
ros .agents/skills/djha-skin-common-lisp/scripts/lisp-check-parens.ros src/*.lisp
```

For each line it prints: the **line number**, the **running paren depth**
(level after processing that line), the number of **left and right parens on
that line**, and a snippet of the line:

```
  252 paren level: 3 | left: 2 | right: 1 | (defun resolve-locations-fn (options)
```

`left` and `right` count only the parens on that line that are actual code
(parens inside strings, line comments, and `#|...|#` block comments are
ignored). The running `paren level` is cumulative across lines, so it goes
negative on an unbalanced close and ends non-zero if the file is unbalanced
(in which case the script exits with status 1 and prints a summary line
naming the file). It exits 0 only when every file's final depth is zero.

To inspect only a specific range of lines, pass `--from N` and/or `--to M`
(1-indexed, inclusive):

```sh
ros .agents/skills/djha-skin-common-lisp/scripts/lisp-check-parens.ros --from 240 --to 260 src/main.lisp
```