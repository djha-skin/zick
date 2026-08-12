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

### Changed

- Default output format is NRDL (zic's yaml default is dropped).

## [0.1.0] - 2026-08-12

### Added

- Beads roadmap for porting zic to Common Lisp (20 issues), including
  the database backend ADR and the ocicl library availability spike.
