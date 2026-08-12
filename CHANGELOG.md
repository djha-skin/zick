# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Project scaffolding: ASDF system `com.djhaskin.zick` with a tests
  system, CLIFF-based entry point, Roswell script, Makefile, and
  ocicl dependency pinning.

### Fixed

- `zick add -m` JSON metadata: NRDL reads JSON object keys back as
  case-preserved keywords (e.g. `:|zick|`), which the metadata
  keywordization skipped, so config-file/ghost-file classification
  (and therefore upgrade put-aside/do-nothing decisions) was silently
  disabled for packages installed with `-m`.  Keys are now normalized
  to the store's uppercase keywords (`:zick`/`:config-files`).
- Smoke tests for the CLI entry point.
- Port of `zic.fs`: archive handling via zippy, SHA-256/CRC-32 via
  ironclad, downloads via dexador/quri, and `.zick-db` marking-file
  search, with a Parachute test suite (60 assertions).
- Port of `zic.db`: the package/file store as FSet persistent records
  (`package-record`/`file`/`store`) serialized to a single NRDL
  document via `slurp-store`/`save-store` (atomic temp + rename),
  with the full query and mutation API (package-id, package-info,
  package-files, owned-by-p, dependers/dependees, add-package,
  insert-file/use, remove-package/files/uses) and a Parachute test
  suite (82 assertions).
- Port of `zic.session`: `with-zick-session` (lock first, then open
  the database), `with-database` (slurp/save the NRDL store at
  `.zick-db/packages.nrdl`), `with-filelock` (a lock file whose
  existence is the lock, created atomically and removed on close,
  with zic's descriptive error text adapted to zick), and
- Black-box test environment: a python3 HTTPS fixture server with a
  self-signed certificate (optional basic auth, user `mode` password
  `code`) serving a wwwroot of `a.zip`/`b.zip`/`c.zip`/`bad.zip`
  (the last with a corrupted entry for CRC-violation testing), plus
  dsolv-style POSIX shell scripts (`tests/resources/scripts/test-*`)
  covering init/add/info/files/verify (exit codes 0/3/4)/remove/
  dependers/dependees, run by `make test-black-box`.
- `zick remove` refusal now names the packages that depend on the
  one being removed, and the dry-run path (`-r`/`--enable-dry-run`)
  is exercised end to end: it reports the full removal set
  (dependers first under `-c`) while leaving the package record, its
  files, and its config-file backups untouched.
- Install-next-to-existing-packages: `zick add` refuses an archive
  whose files are already owned by another package, listing each
  clashing file with its owner; disjoint installs succeed and both
  packages are queryable.  New `package-installable-p` and
  `list-archive-files` helpers back the refusal.
- Install-story test gaps closed: an instrumented test pins the HTTP
  options `fs:download` sends for basic/header/oauth-token
  authorizations and the insecure flag (by recording dexador:get's
  arguments); the store serialization round-trip now also asserts
  package metadata and file classes survive NRDL save/load; and the
  black-box `test-add` verifies the recorded package end to end via
  `info` and `files` on a fresh database.
- CLI download authorizations: `zick add` accepts
  `--json-download-authorizations` (per-host `basic`/`header`/
  `oauth-token` records, parsed with NRDL into `fs:download`'s auth
  table), and `-n`/`--enable-insecure` reaches the HTTP client for
  self-signed fixtures.  CLI subcommand functions renamed to standard
  Common Lisp names (`add-command`, `files-command`, ...; no `!`
  suffix), per the style guide.
  `path-to-connection-string`, with a Parachute test suite (18
  assertions) including a cross-process lock-contention test.
- Port of `zic.package`: install/remove/verify of packages against
  the NRDL store, with config-file upgrade precautions
  (install/put-aside/do-nothing fates and in-place and downgrade
  guards via svers' debian-vercmp), zip-based installs via zippy,
  dependency-aware removal (cascade vs refuse, dry-run, sink-first
  linearization), file-conflict and checksum verification, and the
  package query API, with a Parachute test suite (71 assertions).
- Port of `zic.cli` (`src/main.lisp`): the `zick` command line via
  CLIFF with subcommands `add`, `files`, `info`, `init`, `remove`,
  `dependers`, `dependees`, and `verify` (plus stubbed `list` and
  `orphans`), the zic short aliases, NRDL output, verify exit codes
  3 (package not found) and 4 (verification failures), JSON package
  metadata for `-m` parsed with NRDL, and the deprecated `.zic-db`
  marking-file fallback (with a warning); `cl-json` dropped in
  favor of NRDL's JSON superset parsing, with a CLI integration
  test suite (25 assertions).

### Changed

- Default output format is NRDL (zic's yaml default is dropped).

## [0.1.0] - 2026-08-12

### Added

- Beads roadmap for porting zic to Common Lisp (20 issues), including
  the database backend ADR and the ocicl library availability spike.
