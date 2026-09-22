# Super Productivity MCP Server

Bridge between [Super Productivity](https://github.com/johannesjo/super-productivity/) and MCP
(Model Context Protocol), so Claude can read and manage your tasks, projects and tags.

Fork of [organicmoron/SP-MCP](https://github.com/organicmoron/SP-MCP), with Flatpak support,
a pinned dependency, a working Linux setup script, and Claude Code support.

> **Back up your Super Productivity data before first use.** This plugin writes to your task
> database.

---

## Requirements

| | |
|---|---|
| Super Productivity | 15.0.0 or higher, for `delete_task` (verified on **v19.0.1**, Flatpak) |
| Python | **3.10 or higher** (required by the `mcp` package) |
| `mcp` Python package | **1.x only** — see [Dependency pin](#dependency-pin) |
| Claude client | Claude Code (CLI) **or** Claude Desktop |
| Plugin permission | `nodeExecution` must be granted in Super Productivity |

Works on the Flatpak, AppImage, native and Snap builds of Super Productivity. Windows and macOS
paths are handled in code, but only Linux/Flatpak has been verified by the maintainer of this fork.

### Dependency pin

`requirements.txt` pins `mcp>=1.0.0,<2.0.0`. This is deliberate: **`mcp` 2.x removed the
low-level `Server.list_tools()` decorator API** that this server is built on. Installing an
unpinned `mcp` gets you 2.x and the server dies at startup with:

```
AttributeError: 'Server' object has no attribute 'list_tools'
```

---

## Security notes

Worth understanding before you install this, or any Super Productivity plugin:

- The plugin requires the **`nodeExecution`** permission, which allows arbitrary Node.js code in
  the app's Electron process. This code only uses it for `fs`/`path`/`os` operations in the shared
  directory, but the permission itself is broad.
- **The Flatpak build limits the blast radius.** Super Productivity's Flatpak manifest grants
  `filesystems=home:ro`, so plugin code can only *write* to the app's own data directory and
  `~/Downloads`. The Flatpak is the safer way to run this.
- The plugin and server talk over a **plain directory of JSON files with no authentication**. Any
  local process that can write to it can drive your task database, and task data is mirrored there
  in plaintext. Tighten it if you share the machine:
  ```bash
  chmod 700 <shared dir> <shared dir>/plugin_commands <shared dir>/plugin_responses
  ```
- Nothing here makes network connections. There is no telemetry.

---

## Installation

### Automatic

```bash
git clone https://github.com/ToYoNiX/super-productivity-mcp
cd super-productivity-mcp
chmod +x setup.sh && ./setup.sh
```

`setup.sh` creates a virtual environment, installs the pinned dependency, prints the shared
directory it detected, and registers the server with Claude Code and/or Claude Desktop.

Then install the plugin in the app:

1. Super Productivity → **Settings → Plugins → Upload Plugin**
2. Select `plugin.zip`
3. Grant the **`nodeExecution`** permission and enable the plugin
4. Restart Super Productivity, then restart your Claude client

### Manual

```bash
INSTALL=~/.local/share/super-productivity-mcp
mkdir -p "$INSTALL"
cp mcp_server.py "$INSTALL/"
python3 -m venv "$INSTALL/venv"
"$INSTALL/venv/bin/pip" install -r requirements.txt
```

**Claude Code:**

```bash
claude mcp add super-productivity -s user -- \
  ~/.local/share/super-productivity-mcp/venv/bin/python \
  ~/.local/share/super-productivity-mcp/mcp_server.py
```

**Claude Desktop** — add to `mcpServers` in `claude_desktop_config.json`:

```json
"super-productivity": {
  "command": "/home/you/.local/share/super-productivity-mcp/venv/bin/python",
  "args": ["/home/you/.local/share/super-productivity-mcp/mcp_server.py"]
}
```

Use the venv's Python by absolute path. A bare `python3` will not have `mcp` installed.

---

## How the shared directory is found

The plugin and the server exchange JSON files through a shared directory. Both sides resolve it
independently, in the same order, and each candidate must pass a **write probe** (create a file,
delete it) before it is accepted:

1. `SP_MCP_DATA_DIR` (server only), then `~/.config/super-productivity-mcp/data-dir` if present
2. `~/.var/app/com.super_productivity.SuperProductivity/data/super-productivity-mcp` — Flatpak,
   offered only when that directory already exists
3. `$XDG_DATA_HOME` / `$APPDATA`, when set
4. Platform default — `~/.local/share`, `~/Library/Application Support`, or `%APPDATA%`

The resolved path is shown in the plugin dashboard and logged to `mcp_server.log`.

### Why Flatpak needed a fix

The upstream version does not work on the Flatpak build, and fails silently. Two reasons:

**1. The plugin sandbox has no `process` object.** Super Productivity runs plugin scripts through
`plugin-node-executor.js`, which — for scripts with no dangerous patterns — executes them in an
in-process `vm` context exposing only `fs`, `path`, `os`, `console`, `JSON` and `args`. Upstream
reads `process.env.XDG_DATA_HOME`, which throws `ReferenceError: process is not defined`. The error
is swallowed and a fallback hardcodes `~/.local/share/super-productivity-mcp`.

**2. Under Flatpak, `~/.local/share` is read-only.** Super Productivity ships with
`filesystems=home:ro`, and Flatpak does *not* transparently redirect `~/.local/share` to
`~/.var/app/<id>/data` — that redirection happens only through the `XDG_DATA_HOME` variable, which
the sandboxed script cannot read. So the fallback pointed at a path the plugin could never write
to. The dashboard displayed it, the directories were never created, and every command timed out
after 30 seconds with no error.

This fork detects the directory on disk instead of reading the environment, and verifies each
candidate is writable rather than assuming it.

---

## Usage

```
"Show me all my tasks"
"Create a task to review the quarterly budget #finance +work"
"Mark the budget review task as complete"
"Create a new project called 'Website Redesign'"
```

`delete_task` permanently deletes a task and its sub-tasks. It cannot be undone, so prefer
completing a task unless deletion is what you actually want.

## Dashboard

**Menu → MCP Server** shows the connection status, the resolved shared directory, statistics,
activity logs, and the polling frequency (default 2 seconds).

---

## Building and testing

```bash
./build.sh                       # validate sources and produce plugin.zip
python3 tests/test_e2e.py        # end-to-end test (needs node + the pip requirements)
node tests/test_event_pruning.js # event file cap
```

`tests/test_e2e.py` drives the real scripts from `plugin.js` through a replica of Super
Productivity's plugin sandbox (`tests/plugin_host_replica.js`) against the real MCP server, so the
whole file-based round trip is covered **without installing Super Productivity**. The replica
reproduces the sandbox faithfully, including the absence of a `process` object. The test runs
against a throwaway `HOME` and aborts if directory resolution ever escapes it, so it can never
touch a real install.

`plugin.zip` is built reproducibly: the same commit always produces a byte-identical archive.
A zip stores each file's modification time, so those are pinned to `SOURCE_DATE_EPOCH` — taken
from the environment if set, otherwise from the last commit's date, and clamped to 1980-01-01
because the zip format cannot represent anything earlier. Files are staged in a temporary
directory before stamping, so your working tree is untouched, `TZ=UTC` keeps the stored timestamps
independent of the builder's timezone, and entry modes are normalised to `644` so the builder's
umask does not leak into the archive. Set `SOURCE_DATE_EPOCH` yourself to pin a build to a
specific time.

A local build of a given commit is byte-identical to the one CI produces, verified by comparing
checksums against the uploaded artifact. This assumes the same `zip` implementation; CI uses
Info-ZIP 3.0.

CI (`.github/workflows/test-and-build.yml`) runs those suites on Python 3.10, 3.12 and 3.13, then builds
`plugin.zip` and uploads it as a build artifact. Pushing a `vX.Y.Z` tag additionally checks the tag
matches `manifest.json` and attaches `plugin.zip` to a GitHub release — so you can download a built
plugin from the Releases page instead of building it yourself.

---

## Troubleshooting

**Commands time out after ~30 seconds.** The plugin and server disagree about the shared
directory. Compare the dashboard's "Commands Dir" with the `Using data directory:` line in
`mcp_server.log`. If they differ, set both explicitly:

```bash
mkdir -p ~/.config/super-productivity-mcp
echo "/path/you/want" > ~/.config/super-productivity-mcp/data-dir
```

**`AttributeError: 'Server' object has no attribute 'list_tools'`.** You have `mcp` 2.x.
Reinstall with `pip install -r requirements.txt`.

**Dashboard shows "Not set" / "Ready" forever.** The plugin failed to initialise. Open the
developer console in Super Productivity and look for `MCP Server:` lines, which name every
directory that was tried and why it was rejected.

**Plugin not loading.** Check the Super Productivity version (14.0.0+) and that the plugin has the
`nodeExecution` permission.

---

## Changes in this fork

- Hook event files no longer accumulate. Upstream writes one per task change into
  `plugin_responses/` and never deletes them, although nothing reads them; each is a plaintext
  copy of the task. They are now capped (`maxEventFiles`, default 50), pruned as they are written
  and swept once at startup. Set it to 0 to stop writing them entirely
- CI that tests and builds `plugin.zip`, with releases on tag
- Dashboard layout fixed for long paths: values wrap inside their card instead of colliding
  with their labels, at every window width
- **Task deletion works.** Upstream hardcodes a "deletion not supported" error, which was true
  for Super Productivity 14 but not since 15: `PluginAPI.deleteTask()` exists and routes through
  the same `TaskService.remove()` the UI uses. Now exposed as the `delete_task` tool
- Flatpak support: on-disk detection of the shared directory with a write probe, replacing the
  `process.env` lookup that cannot work in the plugin sandbox
- Same resolution order implemented on the Python side, so both ends agree with no env override
- `mcp` pinned to 1.x
- `setup.sh` rewritten: it referenced a `merge_config_unix.py` that does not exist in the
  repository, so it could not complete on Linux. Now uses a venv and supports Claude Code
- Dashboard menu entry renamed from "MCP Bridge Dashboard" to "MCP Server"
- Dashboard fixed: it read `mcpPath`/`status` while the plugin sent `mcpServerPath`/`isInitialized`,
  so the data directory always showed "Not set" and the badge never left "Ready"
- Initialisation failures now raise with the list of directories tried, instead of silently
  falling back to an unwritable path
- Plugin manifest no longer claims authorship by the Super Productivity team

## License

See [LICENSE.txt](LICENSE.txt).
