#!/usr/bin/env bash
#
# make-source-tarball.sh VERSION
#
# Assemble the source artifacts that feed zick's packaging paths.  zick's
# dependencies include the three unpublished-in-ocicl sibling systems
# com.djhaskin.cliff / com.djhaskin.nrdl / com.djhaskin.svers, so the source
# packages vendor them to stay self-contained.
#
# Produces, in the current directory:
#   zick-<VERSION>-src.tar.gz       combined: top-level dirs zick/ cliff/
#                                   nrdl/ svers/  -> Fedora/RHEL SRPM (Source0)
#   zick_<VERSION>.orig.tar.gz      Debian .orig: top dir zick-<VERSION>/ with
#                                   the zick source at the top level plus
#                                   cliff/ nrdl/ svers/ vendored in
#                                   -> Debian/Ubuntu source package (PPA)
#
# Sibling commits can be pinned in scripts/sibling-pins.txt (one "repo sha"
# pair per line); absent that file (or for repos not listed), the current
# main branch head is used.
#
set -euo pipefail

VERSION="${1:?usage: make-source-tarball.sh VERSION}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PINS="$HERE/sibling-pins.txt"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

clone () {
    local repo="$1" dir="$2"
    git clone --quiet --depth 1 "https://github.com/djha-skin/${repo}.git" "$dir"
    if [ -f "$PINS" ]; then
        local sha
        sha="$(awk -v r="$repo" '$1==r {print $2}' "$PINS")"
        if [ -n "$sha" ]; then
            (cd "$dir" && git fetch --quiet --depth 1 origin "$sha" && git checkout --quiet "$sha")
        fi
    fi
    echo "  $repo @ $(cd "$dir" && git rev-parse --short HEAD)"
}

echo "Fetching sources..."
clone zick   "$TMPD/zick"
clone cliff  "$TMPD/cliff"
clone nrdl   "$TMPD/nrdl"
clone svers  "$TMPD/svers"

# 1) Combined tarball for the RPM path (top-level dirs: zick cliff nrdl svers).
tar czf "zick-${VERSION}-src.tar.gz" -C "$TMPD" zick cliff nrdl svers
echo "wrote $(pwd)/zick-${VERSION}-src.tar.gz"

# 2) Debian .orig tarball: zick source at the top of zick-<VERSION>/ with the
#    siblings vendored alongside.
DEBDIR="$TMPD/zick-${VERSION}"
mkdir -p "$DEBDIR"
( cd "$TMPD/zick" && tar cf - . ) | ( cd "$DEBDIR" && tar xf - )
mv "$TMPD/cliff" "$TMPD/nrdl" "$TMPD/svers" "$DEBDIR/"
tar czf "zick_${VERSION}.orig.tar.gz" -C "$TMPD" "zick-${VERSION}"
echo "wrote $(pwd)/zick_${VERSION}.orig.tar.gz"
