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

echo "==> Building plugin.zip"
rm -f plugin.zip
# -X drops uid/gid and extra attributes so the archive does not vary by builder.
zip -q -X plugin.zip "${PLUGIN_FILES[@]}"

echo "==> Result"
unzip -l plugin.zip | sed 's/^/    /'
echo "    sha256: $(sha256sum plugin.zip | cut -d' ' -f1)"
