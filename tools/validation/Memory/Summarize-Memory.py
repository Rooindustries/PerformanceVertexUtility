import argparse
import csv
import json
import math
from pathlib import Path
import statistics

METRICS = ['workingSetBytes', 'privateBytes', 'privateWorkingSetBytes']
ORDER = ['initial-Home-60s', 'Home', 'Games-Games', 'Games-Processes',
         'Games-Background-apps', 'Remove-apps', 'Graphics-drivers',
         'Windows-tweaks', 'Tools', 'Undo-changes', 'Report-a-bug',
         'Settings', 'Home-return', 'final-Home-60s', 'minimized-60s',
         'unfocused-10s', 'unfocused-40s']
PAGES = ['Windows tweaks', 'Tools', 'Remove apps']
MIB = 1048576


def read_json(path, nonce=None):
    value = json.loads(path.read_text(encoding='utf-8-sig'))
    if nonce and (not isinstance(value, dict) or value.get('nonce') != nonce):
        raise ValueError('JSON invocation nonce differs: ' + str(path))
    return value['data'] if isinstance(value, dict) and 'data' in value and 'nonce' in value else value


def read_csv(path):
    with path.open(encoding='utf-8-sig', newline='') as stream:
        rows = list(csv.DictReader(stream))
    if not rows:
        raise ValueError('CSV contains no measurements: ' + str(path))
    for row in rows:
        row['run'] = int(row['run'])
        if 'pid' in row:
            row['pid'] = int(row['pid'])
        for key in METRICS:
            if key in row:
                row[key] = int(row[key])
    return rows


def flags_and_medians(rows):
    totals = [row for row in rows if row['kind'] == 'total']
    if len({(row['run'], row['point']) for row in totals}) != len(totals):
        raise ValueError('Duplicate total sample')
    flags = []
    for run in sorted({row['run'] for row in totals}):
        app = {row['point']: row for row in rows if row['run'] == run and row['kind'] == 'app'}
        reference = min(app['initial-Home-60s']['privateWorkingSetBytes'], app['Home']['privateWorkingSetBytes'])
        if min(app[p]['privateWorkingSetBytes'] for p in ORDER[2:5]) < reference * 0.5:
            flags.append(run)
    points = list(dict.fromkeys(row['point'] for row in totals))
    medians = []
    for point in points:
        selected = [row for row in totals if row['point'] == point]
        unflagged = [row for row in selected if row['run'] not in flags]
        medians.append({'point': point, 'allN': len(selected), 'unflaggedN': len(unflagged),
                        **{key: {'all': statistics.median(row[key] for row in selected),
                                 'unflagged': statistics.median(row[key] for row in unflagged) if unflagged else None}
                           for key in METRICS}})
    return flags, medians


def timing_summary(rows, flags):
    result = []
    for page in PAGES:
        values = [float(row['milliseconds']) for row in rows if row['page'] == page]
        clean = [float(row['milliseconds']) for row in rows if row['page'] == page and int(row['run']) not in flags]
        if not values or min(values) <= 0:
            raise ValueError('Reopen timings missing or invalid for ' + page)
        result.append({'page': page, 'allN': len(values), 'unflaggedN': len(clean),
                       'allMedianMs': statistics.median(values), 'allMaximumMs': max(values),
                       'unflaggedMedianMs': statistics.median(clean) if clean else None,
                       'unflaggedMaximumMs': max(clean) if clean else None})
    return result


def summarize(root, compare=None):
    invocation = read_json(root / 'measurement-completion.json')['nonce']
    receipt = read_json(root / 'measurement-receipt.json')
    if receipt['status'] != 'pass' or receipt['completedRuns'] != receipt['requestedRuns']:
        raise ValueError('Measurement did not complete every requested run')
    samples = read_json(root / 'memory.json', invocation)
    rows = read_csv(root / 'memory.csv')
    extras = read_json(root / 'post-reopen-memory.json', invocation)
    extra_rows = read_csv(root / 'post-reopen-memory.csv')
    reopens = read_json(root / 'reopen.json', invocation)
    reopen_csv = read_csv(root / 'reopen.csv')
    runs = int(receipt['requestedRuns'])
    if len(samples) != runs * len(ORDER) or len(extras) != runs or len(reopens) != runs * 9:
        raise ValueError('Recipe sample count differs')
    identities = set()
    for run in range(1, runs + 1):
        selected = [s for s in samples if s['run'] == run]
        if [s['point'] for s in selected] != ORDER:
            raise ValueError('Recipe order differs for run ' + str(run))
        app = next(p for p in selected[0]['processes'] if p['kind'] == 'app')
        identity = (app['pid'], app['startTimeUtc'])
        if identity in identities:
            raise ValueError('An app lifetime was reused')
        identities.add(identity)
        previous = 0
        for sample in selected:
            interval = 30 if sample['point'] == 'unfocused-40s' else sample['settleSeconds']
            if sample['total']['elapsedSeconds'] - previous < interval:
                raise ValueError('Prescribed settle was shortened')
            previous = sample['total']['elapsedSeconds']
        extra = next(s for s in extras if s['run'] == run)
        before = next(s for s in selected if s['point'] == 'final-Home-60s')
        after = next(s for s in selected if s['point'] == 'minimized-60s')
        if extra['point'] != 'post-reopen-Home-15s' or extra['settleSeconds'] != 15 or not before['total']['elapsedSeconds'] < extra['total']['elapsedSeconds'] < after['total']['elapsedSeconds']:
            raise ValueError('Post-reopen sample placement differs')
        if after['total']['elapsedSeconds'] - extra['total']['elapsedSeconds'] < 60:
            raise ValueError('Minimized settle was shortened')
        timed = [r for r in reopens if r['run'] == run]
        if [(r['page'], r['repeat']) for r in timed] != [(p, n) for p in PAGES for n in range(1, 4)]:
            raise ValueError('Reopen order differs')
        for item in timed:
            if item['pid'] != identity[0] or item['nonce'] != invocation or item['navigationOperation'] != 'SelectionItemPattern.Select' or item['milliseconds'] < item['selectionReturnedMilliseconds']:
                raise ValueError('Reopen identity or clock differs')
            if item['page'] == 'Tools':
                if item['markerId'] != 'OpenFirmware' or item['markerType'] != 'ControlType.Button':
                    raise ValueError('Tools content marker differs')
            elif item['markerType'] != 'ControlType.ListItem':
                raise ValueError('List content marker differs')
            match = [r for r in reopen_csv if r['run'] == run and r['page'] == item['page'] and int(r['repeat']) == item['repeat']]
            if len(match) != 1 or not math.isclose(float(match[0]['milliseconds']), item['milliseconds'], rel_tol=0, abs_tol=1e-8):
                raise ValueError('Reopen CSV/JSON differs')
    for sample in samples + extras:
        state = 'minimized' if sample['point'] == 'minimized-60s' else 'unfocused' if sample['point'].startswith('unfocused-') else 'active'
        if sample['state'] != state or sample['nonce'] != invocation or sum(p['kind'] == 'app' for p in sample['processes']) != 1:
            raise ValueError('Sample state or app count differs')
        matching = [r for r in rows + extra_rows if r['run'] == sample['run'] and r['point'] == sample['point']]
        if len(matching) != len(sample['processes']) + 1:
            raise ValueError('Sample CSV row count differs')
        for key in METRICS:
            if any(p[key] <= 0 for p in sample['processes']) or sample['total'][key] != sum(p[key] for p in sample['processes']):
                raise ValueError('Sample metrics or total differ')
        for process in sample['processes'] + [sample['total']]:
            match = [r for r in matching if r['pid'] == process['pid']]
            if len(match) != 1 or match[0]['nonce'] != invocation or any(match[0][key] != process[key] for key in METRICS):
                raise ValueError('Memory CSV/JSON differs')
    flags, medians = flags_and_medians(rows + extra_rows)
    result = {'status': 'verified', 'runs': runs, 'samples': len(samples), 'postReopenSamples': len(extras),
              'flags': flags, 'flagRule': 'App private WS at any Games point < 0.5 * min(initial Home, Home).',
              'medians': medians, 'reopen': timing_summary(reopens, flags), 'comparison': None}
    heap_path = root / 'heap-analysis.json'
    if heap_path.exists():
        heap = read_json(heap_path, invocation)
        placement = read_json(root / 'heap-placement.json', invocation)
        final = next(s for s in samples if s['run'] == runs and s['point'] == 'final-Home-60s')
        if heap['pid'] != final['appPid'] or placement['pid'] != heap['pid'] or placement['run'] != runs or placement['point'] != 'final-Home-60s' or not heap['heapCanWalk']:
            raise ValueError('Heap probe is not bound to final Home of the last run')
        if heap['estimatedPrivateBytesOutsideGcSegments'] != heap['privateBytes'] - heap['managedHeapCommittedBytes']:
            raise ValueError('Heap outside-GC remainder differs')
        result['heap'] = {k: heap[k] for k in ['managedObjectBytes', 'managedRootReachableBytes', 'managedHeapCommittedBytes', 'estimatedPrivateBytesOutsideGcSegments', 'limitations']}
    if compare:
        control_rows = read_csv(compare)
        companion = compare.parent / 'post-reopen-memory.csv'
        if companion.is_file() and companion != compare:
            control_rows += read_csv(companion)
        control_flags, control = flags_and_medians(control_rows)
        differences = []
        for point in medians:
            old = next((p for p in control if p['point'] == point['point']), None)
            differences.append({'point': point['point'], **{k: {selection: point[k][selection] - old[k][selection] if old and point[k][selection] is not None and old[k][selection] is not None else None for selection in ['all', 'unflagged']} for k in METRICS}})
        result['comparison'] = {'source': str(compare), 'flags': control_flags, 'medians': control,
                                'differences': differences, 'sign': 'measured minus control; negative saves memory'}
        reopen_path = compare.parent / 'reopen.csv'
        if reopen_path.is_file():
            result['comparison']['reopen'] = timing_summary(read_csv(reopen_path), control_flags)
    (root / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    with (root / 'medians.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=['point', 'selection', 'runs'] + METRICS)
        writer.writeheader()
        for point in medians:
            for selection in ['all', 'unflagged']:
                writer.writerow(dict(point=point['point'], selection=selection, runs=point['allN' if selection == 'all' else 'unflaggedN'], **{k: point[k][selection] for k in METRICS}))
    if result['comparison']:
        with (root / 'differences.csv').open('w', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=['point', 'selection'] + METRICS)
            writer.writeheader()
            for point in result['comparison']['differences']:
                for selection in ['all', 'unflagged']:
                    writer.writerow(dict(point=point['point'], selection=selection, **{k: point[k][selection] for k in METRICS}))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--compare', type=Path)
    args = parser.parse_args()
    result = summarize(args.directory, args.compare)
    print(json.dumps({k: result[k] for k in ['status', 'runs', 'samples', 'flags', 'reopen']}, indent=2))
