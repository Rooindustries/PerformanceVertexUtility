import base64
import csv
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

EPOCH_OFFSET = 116444736000000000


def filetime(value):
    return datetime.fromtimestamp((int(value) - EPOCH_OFFSET) / 10_000_000, tz=timezone.utc)


def label(name, command):
    lowered = name.lower()
    if lowered == 'powershell.exe':
        text = command or ''
        encoded = re.search(r'-EncodedCommand\s+([A-Za-z0-9+/=]+)', text)
        if encoded:
            try:
                text = base64.b64decode(encoded.group(1)).decode('utf-16-le')
            except ValueError:
                pass
        if 'ROO_INDUSTRIES_CONTROL_HELPER' in text:
            return 'embedded control helper'
        script = re.search(r"([A-Za-z0-9.-]+\.ps1)", text)
        return script.group(1) if script else 'powershell (other)'
    if lowered == 'optimizer.host.exe':
        action = re.search(r'Optimizer\.Host\.exe"?\s+([a-z-]+)', command or '')
        return 'Optimizer.Host ' + (action.group(1) if action else '?')
    return name


def main(folder):
    folder = Path(folder)
    processes = {}
    with open(folder / 'processes.csv', encoding='utf-8-sig') as handle:
        for row in csv.DictReader(handle):
            if not row['pid'] or row['pid'].startswith('#'):
                continue
            entry = processes.setdefault(row['pid'] + ':' + row['create_filetime'], {})
            entry.update({key: value for key, value in row.items() if value})
    apps = {key for key, value in processes.items() if value.get('name', '').lower().startswith('rooindustries.optimizationsuite')}
    by_pid = defaultdict(list)
    for key, value in processes.items():
        by_pid[value['pid']].append(key)

    def descends(key, depth=0):
        if key in apps:
            return True
        if depth > 8:
            return False
        parent = processes[key].get('ppid')
        own = int(processes[key].get('create_filetime') or 0)
        candidates = [item for item in by_pid.get(parent, []) if int(processes[item].get('create_filetime') or 0) <= own]
        return any(descends(item, depth + 1) for item in candidates)

    spawned = sorted((filetime(value['create_filetime']), value) for key, value in processes.items()
                     if key not in apps and value.get('create_filetime') and descends(key))
    steps = []
    with open(folder / 'loadtimes.csv', encoding='utf-8-sig') as handle:
        rows = list(csv.DictReader(handle))
    previous = None
    for row in rows:
        end = datetime.fromisoformat(row['utc'].replace('Z', '+00:00'))
        steps.append((previous, end, row['tour'] + ' ' + row['page'] + ' ' + row['visit']))
        previous = end
    lines = ['| step | helper processes | by script or action |', '|---|---|---|']
    totals = Counter()
    for start, end, name in steps:
        inside = [value for created, value in spawned if (start is None or created > start) and created <= end]
        counts = Counter(label(value.get('name', ''), value.get('command_line', '')) for value in inside if value.get('name', '').lower() != 'conhost.exe')
        totals.update(counts)
        lines.append('| ' + name + ' | ' + str(sum(counts.values())) + ' | ' + ', '.join(key + ' x' + str(value) for key, value in counts.most_common()) + ' |')
    lines += ['', '| script or action | total |', '|---|---|']
    lines += ['| ' + key + ' | ' + str(value) + ' |' for key, value in totals.most_common()]
    (folder / 'SPAWNS.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print('\n'.join(lines[-(len(totals) + 3):]))


if __name__ == '__main__':
    main(sys.argv[1])
