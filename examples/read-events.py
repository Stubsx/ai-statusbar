#!/usr/bin/env python3
"""Read-only polling example. First run establishes a cursor; no commands or messages are executed."""
import argparse
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--reset', action='store_true', help='Start at the current end without replay')
args = parser.parse_args()
collector = '/Applications/灵眸.app/Contents/Resources/lingmou-collector'
cursor_file = Path.home() / '.ai-statusbar' / 'example-event-cursor.json'
cursor = json.loads(cursor_file.read_text()) if cursor_file.exists() and not args.reset else None
command = [collector, '--events'] + (['--after', cursor] if cursor else [])
result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=10)
if result.returncode not in (0, 3):
    raise SystemExit(result.stderr.strip() or '无法读取接口')
batch = json.loads(result.stdout)
if batch['schema'] != 1 or not batch['enabled']:
    raise SystemExit('请先在灵眸开启本地事件接口')
if batch['gap'] and not args.reset:
    raise SystemExit('事件保留范围或接口发生变化，请核对后用 --reset 建立新基线')
if cursor:
    for event in batch['events']:
        print(event['id'], event['tool'], event['phase'])
else:
    print('已建立基线，下次运行只读取新增事件')
# Persist only after successful processing. Automation integrations must also deduplicate event IDs.
temporary = cursor_file.with_suffix('.tmp')
fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as handle:
    json.dump(batch['cursor'], handle)
os.replace(temporary, cursor_file)
