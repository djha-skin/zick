# zick

Zip files In Concert. This is a package manager that aims to be:

* Dead simple
* An "RPM" or "DEB" for project-level, source-code repositories
* Based almost completely on plain old zip files

Being that this isn't a "YUM" or "APT" for source code repos, it is
best paired with [dsolv](https://github.com/djha-skin/dsolv), the
Common Lisp port of the Degasolv dependency resolver.

zick is a Common Lisp port of [zic](https://github.com/djhaskin987/zic).

## Usage

Coming soon.

## Building

Build the `zick` executable with:

```bash
./scripts/build
```

## Running the Tests

The test suite runs under [Parachute](https://github.com/Shinmera/parachute)
via ASDF:

```lisp
(asdf:test-system :com.djhaskin.zick)
```

## License

Copyright © 2026 Daniel Jay Haskin

MIT License.
