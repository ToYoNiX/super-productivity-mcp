#!/usr/bin/env bash
# Build plugin.zip from source and validate it.
# Used by CI and by hand: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

PLUGIN_FILES=(index.html manifest.json plugin.js README.md)

echo "==> Validating sources"
node --check plugin.js
echo "    plugin.js      OK"

python3 -c "import ast,sys; [ast.parse(open(f).read()) for f in ('mcp_server.py','merge_config.py')]"
echo "    python sources OK"

# The dashboard ships as one HTML file; check its inline script too.
python3 - <<'PY'
src = open('index.html').read()
s = src.index('<script>') + len('<script>')
open('/tmp/_dash_check.js', 'w').write(src[s:src.index('</script>', s)])
PY
node --check /tmp/_dash_check.js && rm -f /tmp/_dash_check.js
echo "    index.html JS  OK"

VERSION=$(python3 -c "import json; print(json.load(open('manifest.json'))['version'])")
echo "    manifest       OK (version $VERSION)"

# A version tag must match the manifest, or installs silently ship the wrong build.
if [ "${EXPECT_VERSION:-}" != "" ] && [ "${EXPECT_VERSION}" != "$VERSION" ]; then
    echo "ERROR: tag version ${EXPECT_VERSION} != manifest version ${VERSION}" >&2
    exit 1
fi

# Reproducible build. A zip embeds each file's modification time, so two builds
# of identical sources still differ unless those times are pinned. Honour
# SOURCE_DATE_EPOCH when set, otherwise derive it from the last commit, so the
# same commit always yields the same archive.
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    if git rev-parse --git-dir > /dev/null 2>&1; then
        SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
    else
        SOURCE_DATE_EPOCH=315532800   # 1980-01-01, the earliest a zip can store
    fi
fi
# The zip format cannot represent anything before 1980.
if [ "$SOURCE_DATE_EPOCH" -lt 315532800 ]; then
    SOURCE_DATE_EPOCH=315532800
fi
export SOURCE_DATE_EPOCH
echo "    SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH ($(TZ=UTC date -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S UTC'))"

echo "==> Building plugin.zip"
rm -f plugin.zip
OUT="$PWD/plugin.zip"

# Stage a copy so the working tree's own timestamps are left alone, then stamp
# every entry with the pinned time.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "${PLUGIN_FILES[@]}" "$STAGE/"
touch -d "@$SOURCE_DATE_EPOCH" "$STAGE"/*
# A zip records each entry's Unix mode in its external attributes, so the
# builder's umask would otherwise leak into the archive (0664 vs 0644).
chmod 644 "$STAGE"/*

# -X drops uid/gid and the extra timestamp fields; -D omits directory entries;
# TZ=UTC keeps the stored DOS timestamps independent of the builder's timezone.
# Files are passed in a fixed order so entry order is stable too.
( cd "$STAGE" && TZ=UTC zip -q -X -D "$OUT" "${PLUGIN_FILES[@]}" )

echo "==> Result"
unzip -l plugin.zip | sed 's/^/    /'
echo "    sha256: $(sha256sum plugin.zip | cut -d' ' -f1)"
