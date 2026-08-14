---
name: development-workflow
sub-of: djha-skin-common-lisp
description: >
  Skill that describes a typical development working session in
  Common Lisp, Dan Haskin style.
---

# Development Workflow

These steps assume that the repository is cloned and that you are in that
folder.

## Steps

1. Ask the user for instructions on what to build.
2. Ask several questions about specifics so that requirements are not guessed.
3. Check open beads and capture the requested work in beads.
4. Pick up each bead and work it in turn, using TDD and frequent checks.
5. Have a subagent audit the work and address its concerns.
6. Commit and push each completed bead, adding a changelog entry as needed.

## Tooling

* **muxxy** — Drive a `clrepl` process in a tmux pane. Use muxxy for all
  interactive Lisp operations: loading systems, running tests, evaluating
  forms, and inspecting debugger state. Do not use one-off `sbcl` or `ros`
  commands. Use `clrepl`, not raw `sbcl`, because it provides the project's
  Roswell/rlwrap setup.
* **OCICL** — Run `ocicl install` for systems listed in `ocicl.csv`. Do not use
  Qlot or Quicklisp.
* **Roswell** — Use `ros init` for script scaffolding and `ros build` for
  executables. Dependencies come from OCICL.
* For testing, run `(asdf:test-system "com.djhaskin.<name-of-the-repository>")`
  through muxxy.

### Using muxxy

Start a project-local REPL pane and retain the pane id:

```sh
muxxy split-pane --directory "$PWD" --command 'clrepl' --sleep 5
muxxy --pane '%1' --kind sbcl is-repl-ready
muxxy --pane '%1' --kind sbcl execute-command \
  '(asdf:load-system "com.djhaskin.zick/tests")' \
  --timeout 180 --max-lines 10000
muxxy --pane '%1' --kind sbcl execute-command \
  '(asdf:test-system "com.djhaskin.zick")' \
  --timeout 300 --max-lines 30000
```

Use `--directory` so ASDF and OCICL resolve project-local dependencies. Give
loads and test suites generous `--timeout` and `--max-lines` values. Keep the
pane visible while developing, and remove it when finished:
`muxxy --pane '%1' kill-pane`.

The SBCL kind treats `* `, numbered debugger prompts, and `ldb> ` as ready.
When a form drops into the debugger, investigate the error only as much as
needed, then leave immediately with its numbered exit restart. Verify that the
pane is back at `* `; `is-repl-ready` alone is insufficient because `1]` is
also considered ready. Do not use `(abort)`; it is evaluated inside the
debugger and may leave it active. If an error creates a nested prompt such as
`0[2]`, add
`--prompt '^ *[0-9]+(\\[[0-9]+\\]|\\])'` alongside `--kind sbcl`.

Prefer single-line forms. rlwrap's multiline echo can make command capture
stale; use a throwaway form such as `(+ 1 1)` to re-establish a clean boundary.
Large output can cause `get-last-command` to return null unless `--max-lines` is
increased. muxxy returns YAML, with multiline output as a literal block.

### Paren checking

Run the `lisp-check-parens.ros` script (see the Style Guide) before committing
Lisp sources:

```sh
ros .agents/skills/djha-skin-common-lisp/scripts/lisp-check-parens.ros src/*.lisp
```

For each line it prints the line number, running paren depth, counts of left
and right parentheses, and a snippet. It ignores parentheses in strings,
line comments, and block comments. It exits nonzero if a file is unbalanced.
To inspect a range, pass `--from N` and/or `--to M` (1-indexed):

```sh
ros .agents/skills/djha-skin-common-lisp/scripts/lisp-check-parens.ros \
  --from 240 --to 260 src/main.lisp
```
