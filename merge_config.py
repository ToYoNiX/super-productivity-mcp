#!/usr/bin/env python3
"""Merge the Super Productivity MCP server into a Claude Desktop config.

Usage: merge_config.py <config_file> <server_script> [python_bin]
"""
import json
import os
import sys


def merge_claude_config(config_file, server_script, python_bin):
    backup_file = config_file + '.backup'

    try:
        config = {}
        source = backup_file if os.path.exists(backup_file) else config_file
        if os.path.exists(source):
            with open(source, 'r') as f:
                config = json.load(f)

        config.setdefault('mcpServers', {})
        config['mcpServers']['super-productivity'] = {
            'command': python_bin,
            'args': [server_script],
        }

        with open(config_file, 'w') as f:
            json.dump(config, f, indent=2)

        print('Successfully merged the Super Productivity MCP server into the configuration')
        return True

    except Exception as e:
        print(f'Error merging config: {e}')
        return False


if __name__ == '__main__':
    if len(sys.argv) not in (3, 4):
        print('Usage: merge_config.py <config_file> <server_script> [python_bin]')
        sys.exit(1)

    config_path = sys.argv[1]
    script_path = sys.argv[2]
    interpreter = sys.argv[3] if len(sys.argv) == 4 else 'python3'

    sys.exit(0 if merge_claude_config(config_path, script_path, interpreter) else 1)
