# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Project scaffolding: ASDF system `com.djhaskin.zick` with a tests
  system, CLIFF-based entry point, Roswell script, Makefile, and
  ocicl dependency pinning.
- Smoke tests for the CLI entry point.
- Port of `zic.fs`: archive handling via zippy, SHA-256/CRC-32 via
  ironclad, downloads via dexador/quri, and `.zic-db` marking-file
  search, with a Parachute test suite (60 assertions).
- Port of `zic.db`: the package/file store as FSet persistent records
  (`package-record`/`file`/`store`) serialized to a single NRDL
  document via `slurp-store`/`save-store` (atomic temp + rename),
  with the full query and mutation API (package-id, package-info,
  package-files, owned-by-p, dependers/dependees, add-package,
  insert-file/use, remove-package/files/uses) and a Parachute test
  suite (82 assertions).
- Port of `zic.session`: `with-zic-session` (lock first, then open
  the database), `with-database` (slurp/save the NRDL store at
  `.zick-db/packages.nrdl`), `with-filelock` (a lock file whose
  existence is the lock, created atomically and removed on close,
  with zic's descriptive error text adapted to zick), and
  `path-to-connection-string`, with a Parachute test suite (18
  assertions) including a cross-process lock-contention test.

### Changed

- Default output format is NRDL (zic's yaml default is dropped).

## [0.1.0] - 2026-08-12

### Added

- Beads roadmap for porting zic to Common Lisp (20 issues), including
  the database backend ADR and the ocicl library availability spike.
