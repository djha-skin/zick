#!/bin/sh
# Build the zick black-box fixture: wwwroot zips (a/b/c/bad) and a
# self-signed TLS certificate, mirroring zic's lighttpd-environment.
#
# The bad.zip archive has an entry whose content no longer matches its
# stored CRC, for CRC-violation testing.
set -eu

for tool in zip openssl python3; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "${tool} is required for the zick black-box fixture" >&2
        exit 1
    fi
done

root_path="$(cd "$(dirname "$0")/../../.." && pwd)"
fixture_path="${root_path}/tests/resources/fixture"
wwwroot="${fixture_path}/wwwroot"
test_data="${fixture_path}/test-data"

rm -rf "${wwwroot}" "${test_data}"
mkdir -p "${wwwroot}" "${test_data}"

# Package content, mirroring zic's lighttpd.sh fixture.
mkdir -p "${test_data}/c" "${test_data}/b/d" "${test_data}/a"
echo 'I am an echo.' > "${test_data}/c/echo.txt"
echo 'Hopscotch.' > "${test_data}/b/d/hoarcrux.txt"
echo 'Fie on goodness! Fie! Fie! Fie! Fie!' > "${test_data}/b/fie.txt"
echo "I can't stop this feeling deep inside of me" > "${test_data}/a/poem.txt"
echo 'The wind in the' > "${test_data}/a/willows.txt"

(cd "${test_data}" && zip -qr "${wwwroot}/a.zip" a)
(cd "${test_data}" && zip -qr "${wwwroot}/b.zip" b)
(cd "${test_data}" && zip -qr "${wwwroot}/c.zip" c)

# bad.zip: a STORED entry whose content byte is flipped after zipping,
# so the stored CRC no longer matches the content.
python3 - "${wwwroot}/bad.zip" <<'PYEOF'
import sys
import zipfile

path = sys.argv[1]
with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as zf:
    zf.writestr("a.txt", b"hello")
with open(path, "rb") as f:
    data = bytearray(f.read())
i = data.find(b"hello")
assert i >= 0, "content byte not found in bad.zip"
data[i] = ord("X")
with open(path, "wb") as f:
    f.write(bytes(data))
PYEOF

# Self-signed TLS certificate for the fixture server (regenerated only
# when missing, so the cert stays stable across runs).
if [ ! -e "${fixture_path}/server.pem" ]; then
    openssl req -x509 -newkey rsa:2048 \
        -keyout "${fixture_path}/server.pem" \
        -out "${fixture_path}/server.pem" \
        -days 3650 -nodes -subj "/CN=localhost" >/dev/null 2>&1
fi

echo "zick fixtures ready in ${wwwroot}"
