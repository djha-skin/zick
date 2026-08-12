# Writing Documentation

How to write and ship the documentation for a Common Lisp project in this
ecosystem, following the pattern established by `cliff`, `svers`, and `dsolv`.

## Stack

* **codex** builds the docs from a CommonDoc document tree.
  * Docs: <https://commondoc.github.io/codex/>
* **scriba** is the markup language the manual is written in.
  * Reference: <https://commondoc.github.io/scriba/docs/reference.html>
* The site is published to **GitHub Pages** from a workflow in
  `.github/workflows/docs.yml` (model it on the `svers`/`cliff` workflows).
* Dependencies come from **ocicl** (see `development-workflow.md`); do not use
  Quicklisp. The `ocicl.csv` must include the whole codex ecosystem: `codex`,
  `codex-templates`, `scriba`, `pandocl`, `docparser`, `common-doc`,
  `common-html`, `common-doc-plump`, `common-doc-split-paragraphs`,
  `common-doc-tex`, `common-doc-contrib`, `parenml`, `cl-indentify`,
  `djula`/`cl-ppcre` as needed, plus the project's own runtime dependencies.

## Layout

Keep the manual in small scriba files that are concatenated at build time;
do not edit one giant `manual.scr` by hand.

```
docs/
  manifest.lisp        # codex manifest (system name, title, sources)
  scriba/
    01-overview.scr    # one section per file, numbered for order
    02-get-dsolv.scr
    ...
    14-api-reference.scr
  manual.scr           # GENERATED: cat docs/scriba/*.scr > docs/manual.scr
  build-docs.ros       # codex:document + post-processing (see below)
  assets/              # logos, images (referenced with @image[src=...])
  build/               # GENERATED: codex output (gitignored)
  *.html               # GENERATED: rsync'd site, committed for review
scripts/
  update-docs          # assemble manual.scr, build, rsync build output into docs/
Makefile               # make docs: HTML + simple HTML + manual.pdf
```

The manifest (`docs/manifest.lisp`) looks like:

```lisp
(:docstring-markup-format :scriba
 :systems ("com.djhaskin.example")
 :documents ((:title "example: The Example"
              :authors ("First Last")
              :output-format (:type :multi-html
                              :template :minima)
              :sources ("manual.scr"))))
```

## The scriba manual

* The top-level section of the manual is `@begin(section)` with `@title(...)`
  — there is **no** `@begin(document)` wrapper.
* Nested sections are `@begin(section)`/`@end(section)` inside a section.
* Because codex emits one HTML page per **top-level** section, each
  `docs/scriba/*.scr` file should contain exactly one top-level section (plus
  its subsections).
* Useful markup: `@code(...)`/`@c(...)`, `@b(...)`, `@i(...)`,
  `@link[uri="..."]()`, `@image[src=assets/foo.png]()`, `@list`, `@item`,
  `@begin[lang=lisp](code)` for code blocks.
* API reference sections use codex macros:
  `@cl:with-package[name="com.djhaskin.example"](...)` wrapping
  `@begin(section)`/`@title(@c(symbol))`/`@cl:doc(function symbol)`
  blocks. `@cl:doc` inserts the symbol's docstring, so every referenced
  function needs a docstring or the build fails with
  `CODEX.ERROR:NO-DOCSTRING`.
* When porting docs from another project (e.g. degasolv's Sphinx `.rst`):
  adapt the copy to the new project's CLI and identity; do not copy logos from
  projects you do not own.

### Command reference, not help dumps

Do not paste entire CLIFF help pages into the docs. Instead, in each
subcommand's section, list the arguments that subcommand uses, with their
defaults and aliases.

## Build pipeline

* `docs/build-docs.ros` runs `codex:document`, then re-parses `manual.scr`
  with the same machinery codex uses and fixes the broken multi-html TOC
  links (see below).
* `Makefile` targets:
  * `docs/manual.scr` — concatenates the scriba parts.
  * `$(HTML_FILES)` — runs `./docs/build-docs.ros`, copies `docs/assets/`
    into the html dir, and symlinks `index.html` → `overview.html`.
  * `$(SIMPLE_DIR)/%.html` — strips the TOC/sidebar (xmlstarlet + sed) for
    the PDF.
  * `$(HTML_DIR)/manual.pdf` — pandoc over the simple HTML files (needs a
    full TeX install; local machines often lack `mf`, which is fine — CI
    has TeX).
* `scripts/update-docs` (copied from svers and adapted): `cat`s the scriba
  sources, runs the build, and `rsync`s the html dir into `docs/` so the
  generated site can be committed.

## The multi-html TOC link quirk (work around it!)

This codex version calls `(multi-emit doc dir :max-depth 1)`: each top-level
section becomes a page and everything nested becomes an anchor. The TOC,
however, is rendered per page *while* the section→file map is still being
filled, so **nested sections of pages that are emitted later get broken
`foo.html` links** (the file does not exist). The published svers docs have
this bug too.

`docs/build-docs.ros` fixes it after building:

1. Re-parse `manual.scr` exactly like `codex:load-document` (bind
   `codex.markup:*current-markup-format*` to `(pandocl:guess-format ...)`).
2. Walk the tree mapping every section reference to its top-level page
   reference. Sections wrapped in non-section container nodes (scriba wraps
   the top level in a `content-node`) still count as top-level.
3. Rewrite `href="NESTED.html"` → `href="PAGE.html#NESTED"` in every
   generated html file.

Notes:

* Do **not** call `common-doc.macro:expand-macros` outside of
  `codex:document`: the `@cl:doc` macros need `codex.macro:*index*`, which is
  only bound while codex builds. Skip expansion — the section tree (and its
  refs, slugified from titles by `fill-unique-refs`) is identical.
* `uiop:write-file-string` does not exist in this UIOP; write with
  `with-open-file`.

## GitHub Pages

* The workflow mirrors `svers`'s: a `djhaskin987/roswell-sbcl-ocicl`
  container, `ocicl install`, `make docs`, then `configure-pages` /
  `upload-pages-artifact` / `deploy-pages`, uploading
  `docs/build/<slug>/html/`.
* ocicl hooks `asdf:*system-definition-search-functions*` and serves the
  systems listed in the repo's `ocicl.csv` from `<repo>/ocicl/` — so setting
  `CL_SOURCE_REGISTRY` does not break ocicl system discovery. Use it to make
  sibling repositories (e.g. `cliff`, `nrdl`, `svers`) visible by cloning
  them under `systems/` and exporting
  `CL_SOURCE_REGISTRY="$PWD/systems//:"`.
* Enable Pages once per repo with
  `gh api repos/<owner>/<repo>/pages -X POST -f build_type=workflow`
  (or `-X PATCH` if the `pages` resource already exists with another
  build type).

## Verification

* `make docs` should complete the HTML pipeline locally; a PDF failure is
  expected on machines without a working TeX.
* After building, check for broken links:
  `grep -o 'href="[a-z0-9-]*\.html"' *.html | ...` and confirm every target
  file exists.
* Commit the generated `docs/*.html` and `docs/assets/` alongside the
  sources so reviewers can see the site.
