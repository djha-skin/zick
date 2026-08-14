# Changelog — djha-skin-common-lisp

All notable changes to this skill will be documented here.

## [Unreleased]

### Changed

- Development and style workflows now use muxxy to drive a project-local
  `clrepl` pane instead of swanky/swank.
- Documented muxxy's SBCL debugger restart, nested-prompt, multiline-echo, and
  large-output workarounds.

### Fixed

- lisp-check-parens.ros: handle escaped quotes (`\"`) inside strings via a
  backslash-run counter so multi-line docstrings containing escaped quotes
  plus example parens no longer report unbalanced parens.
- lisp-check-parens.ros: skip `#\X` character literals (single chars like
  `#\;` and named chars like `#\Space`) so their contents are not mistaken
  for comments, strings, or parens.

## [0.1.0] - 2025-07-31

### Added

- Initial skill definition: SKILL.md with directory of subskills.
- New Project subskill: step-by-step project setup using qlot, ASDF, Roswell.
- Development Workflow subskill: TDD cycle with beads, swanky, and subagents.
- Style Guide subskill: conventions for naming, formatting, comments, and
  parachute tests.
- CLIFF Command Line Tool subskill: CLI setup with cliff.

### Fixed

- SKILL.md reference corrected from `main-process.md` to
  `development-workflow.md`.

### Changed

- Style guide: added `ros fmt` recommendation for automated formatting.
- Development Workflow: replaced cl-mcp with swanky for Lisp operations.
- Style guide: replaced cl-mcp directive with swanky + lisp-check-parens.ros.
- lisp-check-parens.ros: now prints per-line left/right paren counts and the
  line number alongside the running paren depth; added `--from N` / `--to M`
  options to limit output to a range of lines. Updated the Development Workflow
  Paren checking section to document the new output format and options.

### Fixed

- MCP config: moved from `.agents/mcp.json` to `.mcp.json` (per pi-mcp-adapter
  config file precedence). Removed non-standard `type` field from config.