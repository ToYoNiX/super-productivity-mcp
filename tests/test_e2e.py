#!/usr/bin/env python3
"""End-to-end test: the real MCP server against the real plugin.js scripts.

Runs plugin.js's node scripts through a replica of Super Productivity's plugin
sandbox, so the whole file-based round trip is exercised with no app installed.

Usage: python3 tests/test_e2e.py
"""
import json
import os
import queue
import shutil
import tempfile
import subprocess
import sys
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(REPO, 'mcp_server.py')
REPLICA = os.path.join(REPO, 'tests', 'plugin_host_replica.js')
PLUGIN = os.path.join(REPO, 'plugin.js')


def reader(stream, q):
    for line in stream:
        q.put(line)


def sandbox_env(home):
    """A clean environment rooted at a throwaway HOME.

    Both sides resolve their data directory from HOME, so overriding it keeps the
    test off any real install. XDG_DATA_HOME and SP_MCP_DATA_DIR are dropped
    because they would take priority over that HOME.
    """
    env = dict(os.environ)
    env['HOME'] = home
    env.pop('XDG_DATA_HOME', None)
    env.pop('SP_MCP_DATA_DIR', None)
    return env


def start_host(env):
    """Start the plugin host replica and wait for it to resolve its directory."""
    p = subprocess.Popen(['node', REPLICA, PLUGIN, '60'],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, bufsize=1, env=env)
    q = queue.Queue()
    threading.Thread(target=reader, args=(p.stdout, q), daemon=True).start()
    deadline = time.time() + 20
    while time.time() < deadline:
        try:
            line = q.get(timeout=1)
        except queue.Empty:
            continue
        if line.startswith('HOST_READY'):
            return p, q, line.split(' ', 1)[1].strip()
        if line.startswith('FAIL'):
            raise SystemExit('host replica failed: ' + line)
    raise SystemExit('host replica did not become ready')


def run(home):
    env = sandbox_env(home)
    host, host_q, host_dir = start_host(env)
    print(f'  plugin host ready, resolved: {host_dir}')

    # Hard stop: if resolution ever escapes the sandbox, fail before writing
    # commands that a real Super Productivity could pick up.
    if not host_dir.startswith(home):
        host.terminate()
        raise SystemExit(f'ABORT: resolved {host_dir} outside sandbox {home}')

    srv = subprocess.Popen([sys.executable, SERVER],
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, text=True, bufsize=1, env=env)
    q = queue.Queue()
    threading.Thread(target=reader, args=(srv.stdout, q), daemon=True).start()

    def send(obj):
        srv.stdin.write(json.dumps(obj) + '\n')
        srv.stdin.flush()

    def wait_for(msg_id, timeout=35):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                line = q.get(timeout=1)
            except queue.Empty:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if d.get('id') == msg_id:
                return d
        return None

    failures = []

    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2024-11-05", "capabilities": {},
        "clientInfo": {"name": "test", "version": "1"}}})
    if wait_for(1) is None:
        failures.append('initialize')
        print('  [1] initialize      : FAIL')
    else:
        print('  [1] initialize      : PASS')
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    listed = wait_for(2)
    tools = [t['name'] for t in listed['result']['tools']] if listed else []
    expected = {'create_task', 'get_tasks', 'update_task', 'delete_task',
                'complete_and_archive_task', 'get_projects', 'create_project',
                'get_tags', 'create_tag', 'show_notification'}
    missing = expected - set(tools)
    if missing:
        failures.append(f'tools/list missing {missing}')
        print(f'  [2] tools/list      : FAIL (missing {missing})')
    else:
        print(f'  [2] tools/list      : PASS ({len(tools)} tools)')

    calls = [
        (3, 'get_tasks', {}),
        (4, 'create_task', {"title": "CI task @1days #ci"}),
        (5, 'update_task', {"task_id": "t1", "is_done": True}),
        (6, 'delete_task', {"task_id": "t1"}),
        (7, 'get_projects', {}),
        (8, 'get_tags', {}),
    ]
    for mid, name, args in calls:
        send({"jsonrpc": "2.0", "id": mid, "method": "tools/call",
              "params": {"name": name, "arguments": args}})
        r = wait_for(mid)
        if r is None:
            failures.append(name)
            print(f'  [{mid}] {name:<16}: FAIL (no response)')
            continue
        txt = r['result']['content'][0]['text']
        ok = 'Timeout' not in txt and "'success': True" in txt
        if not ok:
            failures.append(name)
        print(f'  [{mid}] {name:<16}: {"PASS" if ok else "FAIL"} -> {txt[:70]}')

    # delete_task must reject a missing id rather than silently deleting nothing.
    # The mcp package validates the input schema first and answers with isError,
    # so either that or the server's own guard message counts as a pass.
    send({"jsonrpc": "2.0", "id": 9, "method": "tools/call",
          "params": {"name": "delete_task", "arguments": {}}})
    r = wait_for(9, timeout=10)
    ok = False
    if r is not None and 'result' in r:
        text = r['result']['content'][0]['text']
        ok = r['result'].get('isError') is True or 'task_id is required' in text
    if not ok:
        failures.append('delete_task validation')
    print(f'  [9] delete_task guard: {"PASS" if ok else "FAIL"}')

    srv.stdin.close()
    srv.wait(timeout=10)
    host.terminate()

    print()
    if failures:
        print('RESULT: FAILED ->', ', '.join(failures))
        return 1
    print('RESULT: ALL PASS')
    return 0


def main():
    home = tempfile.mkdtemp(prefix='sp-mcp-test-')
    try:
        return run(home)
    finally:
        shutil.rmtree(home, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
