#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo "Super Productivity MCP Server - Setup"
echo "============================================"
echo

# --- Python -----------------------------------------------------------------
if ! command -v python3 &> /dev/null; then
    echo "ERROR: python3 is not installed or not in PATH"
    echo "Please install Python 3.10 or higher"
    exit 1
fi

PY_OK=$(python3 -c 'import sys; print(1 if sys.version_info >= (3, 10) else 0)')
if [ "$PY_OK" != "1" ]; then
    echo "ERROR: Python 3.10 or higher is required (found $(python3 -V 2>&1))"
    exit 1
fi

# --- Install location -------------------------------------------------------
# The server code lives here. This is NOT the directory shared with the plugin;
# that one is detected at runtime (see README).
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/super-productivity-mcp"
mkdir -p "$INSTALL_DIR"

echo "Installing server to: $INSTALL_DIR"
cp mcp_server.py "$INSTALL_DIR/mcp_server.py"
cp plugin.zip "$INSTALL_DIR/plugin.zip" 2>/dev/null || true

# --- Virtual environment ----------------------------------------------------
# A venv avoids "externally-managed-environment" errors on modern distros and
# pins the mcp package, which must stay on 1.x (2.x removed the low-level API
# this server is built on).
echo "Creating virtual environment..."
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
echo "Installing dependencies..."
"$INSTALL_DIR/venv/bin/pip" install --quiet -r requirements.txt

PYTHON_BIN="$INSTALL_DIR/venv/bin/python"
SERVER_PATH="$INSTALL_DIR/mcp_server.py"

# --- Report the detected shared directory -----------------------------------
echo
echo "Detecting the directory shared with Super Productivity..."
DATA_DIR=$("$PYTHON_BIN" - "$SERVER_PATH" << 'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sp_mcp", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
srv = mod.SuperProductivityMCPServer.__new__(mod.SuperProductivityMCPServer)
srv.setup_directories()
print(srv.base_dir)
PYEOF
)
echo "  -> $DATA_DIR"
if [[ "$DATA_DIR" == *"/.var/app/com.super_productivity.SuperProductivity/"* ]]; then
    echo "  (Flatpak install detected)"
fi

# --- Register with a Claude client ------------------------------------------
echo
REGISTERED=0

if command -v claude &> /dev/null; then
    echo "Registering with Claude Code..."
    if claude mcp add super-productivity -s user -- "$PYTHON_BIN" "$SERVER_PATH"; then
        REGISTERED=1
    else
        echo "  Could not register automatically (it may already exist)."
        echo "  To replace it:  claude mcp remove super-productivity -s user"
    fi
fi

CLAUDE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude_desktop_config.json"
if [[ "$OSTYPE" == "darwin"* ]]; then
    CLAUDE_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
fi

if [ -f "$CLAUDE_CONFIG" ]; then
    echo "Configuring Claude Desktop..."
    cp "$CLAUDE_CONFIG" "$CLAUDE_CONFIG.backup"
    if python3 merge_config.py "$CLAUDE_CONFIG" "$SERVER_PATH" "$PYTHON_BIN"; then
        REGISTERED=1
    else
        echo "ERROR: Failed to merge configuration. Backup at $CLAUDE_CONFIG.backup"
    fi
fi

if [ "$REGISTERED" != "1" ]; then
    echo "No Claude client was configured automatically. Add this manually:"
    echo
    echo '  "super-productivity": {'
    echo "    \"command\": \"$PYTHON_BIN\","
    echo "    \"args\": [\"$SERVER_PATH\"]"
    echo '  }'
fi

# --- Done -------------------------------------------------------------------
cat <<EOF

============================================
Setup complete
============================================

Next steps:
1. Install the plugin in Super Productivity:
     Settings > Plugins > Upload Plugin
     Select: $INSTALL_DIR/plugin.zip
2. Grant the plugin the "nodeExecution" permission and enable it.
3. Restart Super Productivity, then restart your Claude client.

Server:      $SERVER_PATH
Shared dir:  $DATA_DIR
Log file:    $DATA_DIR/mcp_server.log
EOF
