![zick logo](docs/assets/zick.png)

# zick

**Zip files In Concert.** A package manager for project-level source-code
repositories, written in Common Lisp.

zick is an "RPM" or "DEB" for your project, not your whole machine: it
installs zip archives into a project tree, tracks which files each package
owns, and verifies the result on disk. It aims to be dead simple and based
almost completely on plain old zip files — no special archive format, no
build step to publish, nothing to compile on the consumer side.

zick is a Common Lisp port of [zic](https://github.com/djhaskin987/zic), and
it is best paired with [dsolv](https://github.com/djha-skin/dsolv), the Common
Lisp port of the Degasolv dependency resolver.

## Why zick?

Most package managers solve *machine-level* problems: installing system
libraries, resolving versions across a whole OS. zick solves a smaller,
neater one — *project-level* artifacts.

If you work on source code, you probably have this situation: your project
needs a handful of binary artifacts or vendored dependencies (a toolchain
bundle, a set of prebuilt libraries, a data pack), and today you either check
them into git, or trust a `download.sh` script to fetch them, or hand-roll an
install step in CI. None of those tell you *what* is installed, *which
version* it is, or *whether the files on disk match what you installed*.

zick makes that explicit:

* **Declare** — `zick add` records a package by name, version, and URL, and
  unpacks its zip into your project tree.
* **Track** — zick keeps an ownership database (in `.zick-db/` under your
  project) of every file each package installed, its size, its checksum, and
  whether it is a configuration file or an ordinary file.
* **Verify** — `zick verify` checks the files on disk against the database,
  so a `git clean` or a bad deploy can't silently break your environment.
* **Clean up** — `zick remove` uninstalls a package (optionally cascading to
  packages that depend on it), and `zick orphans` lists the packages that
  nothing else depends on.

Because everything is a plain zip over HTTP(S), publishing is as simple as
uploading a file, and installing works on any machine with zick and network
access. zick is built for two audiences: **dev machines**, where you set up
the dependencies you need to do programming work, and **CI/CD**, where a
checkout plus `zick add` plus `zick verify` is a reproducible, auditable
install step.

## zick and dsolv

zick and dsolv are independent tools, built to pair well together:

* **dsolv** is a *generic dependency resolver*. You give it a repository of
  cards describing versions and requirements, and it tells you the exact set
  of versions a build needs — returning the URLs of the files to download.
* **zick** is a *package installer*. You give it those URLs, and it downloads,
  unpacks, tracks, and verifies the files in your project tree.

The two fit together like this in a build: dsolv resolves *which* versions
your project needs and hands you the URLs; zick fetches *those exact*
archives, installs them into the project, and proves they are intact. dsolv
answers "what do we need?"; zick answers "make it so, and check."

## Usage

Every command reads its options from the same sources, in order of
precedence: configuration files, environment variables, then the command
line. Output is NRDL by default.

Start a project (creates the `.zick-db/` marking directory):

```bash
zick init
```

Install a package from a zip URL. `-k` names it, `-V` versions it, and `-l`
locates it:

```bash
zick add -k mylib -V 1.2.0 -l https://example.com/mylib-1.2.0.zip
```

`-W` skips the download and records the package without unpacking its files
(useful for metadata-only records or tests), and `-u` declares a dependency
on another installed package:

```bash
zick add -k myapp -V 0.1.0 -l https://example.com/myapp.zip -u mylib
```

See what's installed:

```bash
zick list
```

```
{
    packages [
        {
            location "https://example.com/mylib-1.2.0.zip"
            metadata [
            ]
            name "mylib"
            version "1.2.0"
        }
        {
            location "https://example.com/myapp.zip"
            metadata [
            ]
            name "myapp"
            version "0.1.0"
        }
    ]
    result successful
    status successful
}
```

Ask who depends on what:

```bash
zick dependers -k mylib
zick dependees -k myapp
```

Inspect a package or its files:

```bash
zick info -k myapp
zick files -k myapp
```

Check that the files on disk still match what was installed (exits nonzero
on a mismatch):

```bash
zick verify -k myapp
```

Uninstall, optionally cascading to dependents (`-c`), or dry-running
(`-r`):

```bash
zick remove -k myapp -c
```

Find the cruft — packages nothing else depends on:

```bash
zick orphans
```

`zick` with no subcommand prints a short usage summary; `zick help` prints
the full CLIFF help page.

## Documentation

The full manual — quickstart, a longer example, command reference,
architecture, recipes, and API reference — is published at
[**djha-skin.github.io/zick**](https://djha-skin.github.io/zick/).

## Building

Build the `zick` executable with:

```bash
./scripts/build
```

The build script bakes the large heap and control-stack sizes needed for
big repository resolutions into the binary; override them with the
`DYNAMIC_SPACE_SIZE` and `CONTROL_STACK_SIZE` environment variables if your
use case needs different values.

## Running the Tests

The Lisp test suite runs under [Parachute](https://github.com/Shinmera/parachute)
via ASDF:

```lisp
(asdf:test-system :com.djhaskin.zick)
```

The black-box suite exercises the built binary end to end against a local
fixture HTTPS server:

```bash
./tests/resources/scripts/test-all
```

## Status

zick is an active Common Lisp port of the zic package manager. It is
developed on top of the [CLIFF](https://github.com/djha-skin/cliff) command
line framework, the [NRDL](https://github.com/djha-skin/nrdl) data language,
and FSet persistent data structures.

## License

Copyright © 2026 Daniel Jay Haskin

MIT License.
