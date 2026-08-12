# Agent Instructions

## Beads Issue Tracking

This project uses **bd (beads)** for issue tracking. See [bd prime] for
full workflow context.

The `djha-skin-common-lisp` skill lives in
`.agents/skills/djha-skin-common-lisp/` and covers project setup, development
workflow, and style guidelines for Common Lisp code in this repo. Run `bd prime` for full workflow context.

> Issues live in the local Dolt database (`.beads/dolt/`); sync Beads with `bd dolt push`.

## Quick Reference

```bash
bd ready
bd show <id>
bd update <id> --claim
bd close <id>
bd dolt push
```

## Non-Interactive File Operations

Always use non-interactive flags with shell file operations.

## Common Lisp Porting Rules

### FSet and gmap

Use FSet persistent data structures for resolver data. **Do not use `fset:map`
for ordinary iteration over sequences**. `fset:map` operates on map/pair data;
use the `gmap` generalized mapping facility for sequence mapping and collection
transforms.

Read the authoritative documentation before changing mapping code:
https://fset.common-lisp.dev/Modern-CL/Top_html/GMap.html

Examples:

```lisp
(gmap (:result fset:seq) #'function-to-call
      (:arg fset:seq input-seq))

(gmap (:result list) #'function-to-call
      (:arg fset:seq input-seq))

(gmap (:result fset:seq) #'cons
      (:arg fset:seq seq1)
      (:arg fset:seq seq2))

(gmap (:result list) #'list
      (:arg fset:map input-map))
```

`fset:do-map` is appropriate for direct traversal of an FSet map when the
operation is not a generalized mapping transform. Use `gmap` for mapping
values, mapping sequences, and converting collection results.

### Port naming conventions

When porting Clojure/zic artifacts to Common Lisp/dsolv:

- Replace the **EDN** format name with **NRDL** (for example, `subproc-edn`
  becomes `subproc-nrdl`).

### Other rules

- Use `defstruct` for data records.
- Use `swanky` for Lisp interaction, loading, editing, testing, and builds.
- Use CLIFF `data-slurp`/`base-slurp`; do not reimplement them.
- Use Parachute for tests.

## Build and Test

Run Lisp through swanky. Build the executable with:

```bash
./scripts/build
```

The build script bakes the large heap and control-stack sizes needed for
big repository resolutions (e.g. test-apt's 19 MB APT index) into the
binary; see `scripts/build` for override knobs.

## Session Completion

Before ending a session, update Beads, run quality gates, commit changes, push
to the remote, and verify the working tree is synchronized.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
