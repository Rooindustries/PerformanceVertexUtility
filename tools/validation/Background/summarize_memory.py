import argparse
import csv
import json
import statistics
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('--baseline-summary', type=Path, required=True)
    args = parser.parse_args()
    samples = json.loads((args.root / 'memory.json').read_text(encoding='utf-8-sig'))
    with (args.root / 'memory.csv').open(encoding='utf-8-sig', newline='') as stream:
        rows = list(csv.DictReader(stream))
    order = ['initial-Home-60s', 'Home', 'Games-Games', 'Games-Processes',
             'Games-Background-apps', 'Remove-apps', 'Graphics-drivers',
             'Windows-tweaks', 'Tools', 'Undo-changes', 'Report-a-bug',
             'Settings', 'Home-return', 'final-Home-60s', 'minimized-60s']
    focus = ['unfocused-10s', 'unfocused-40s']
    metrics = ['workingSetBytes', 'privateBytes', 'privateWorkingSetBytes']
    require(len(samples) == 51, 'Expected three runs of seventeen samples')
    require(len({s['appPid'] for s in samples}) == 3, 'Expected three app lifetimes')
    require(len(rows) == sum(len(s['processes']) + 1 for s in samples),
            'CSV has missing or extra process rows')
    runs = []
    for run in range(1, 4):
        selected = [s for s in samples if s['run'] == run]
        require([s['point'] for s in selected] == order + focus,
                f'Run {run} has an unexpected page order')
        require(len({s['appPid'] for s in selected}) == 1, f'Run {run} app changed')
        previous = 0
        for sample in selected:
            point = sample['point']
            minimum = 30 if point == 'unfocused-40s' else sample['settleSeconds']
            require(sample['total']['elapsedSeconds'] - previous >= minimum,
                    f'Run {run} {point} settled for too little time')
            previous = sample['total']['elapsedSeconds']
            state = 'unfocused' if point in focus else (
                'minimized' if point == 'minimized-60s' else 'active')
            require(sample['state'] == state, f'Run {run} {point} state differs')
            processes = sample['processes']
            require(sum(p['kind'] == 'app' and p['pid'] == sample['appPid']
                        for p in processes) == 1, f'Run {run} {point} app missing')
            require(len({p['pid'] for p in processes}) == len(processes),
                    f'Run {run} {point} has duplicate process identities')
            for metric in metrics:
                require(all(p[metric] > 0 for p in processes),
                        f'Run {run} {point} has an invalid {metric}')
                require(sample['total'][metric] == sum(p[metric] for p in processes),
                        f'Run {run} {point} total differs for {metric}')
            csv_sample = [r for r in rows if int(r['run']) == run and r['point'] == point]
            require(len(csv_sample) == len(processes) + 1,
                    f'Run {run} {point} CSV count differs')
            for process in processes + [sample['total']]:
                matching = [r for r in csv_sample if int(r['pid']) == process['pid']]
                require(len(matching) == 1, f'Run {run} {point} CSV PID differs')
                require(all(int(matching[0][m]) == process[m] for m in metrics),
                        f'Run {run} {point} CSV metrics differ')
            if state == 'active':
                require(sample['visibleText'] and
                        (args.root / f"run{run}-{point}.png").is_file(),
                        f'Run {run} {point} has no rendering evidence')
        lookup = {s['point']: s for s in selected}
        record = {'run': run, 'pid': selected[0]['appPid'], 'samples': len(selected),
                  'maximumHelpersAtSample': max(len(s['processes']) - 1 for s in selected)}
        for point in ['initial-Home-60s', 'Windows-tweaks', 'Tools',
                      'final-Home-60s', 'minimized-60s'] + focus:
            record[point] = {m: lookup[point]['total'][m] for m in metrics}
        record['peak'] = {m: max(s['total'][m] for s in selected if s['point'] in order)
                          for m in metrics}
        record['minimizedCpuMilliseconds'] = (
            lookup['minimized-60s']['total']['cpuMilliseconds'] -
            lookup['final-Home-60s']['total']['cpuMilliseconds'])
        runs.append(record)
    baseline = json.loads(args.baseline_summary.read_text(encoding='utf-8-sig'))
    require(baseline['status'] == 'verified', 'Baseline summary is unverified')
    comparison = {}
    for point in ['initial-Home-60s', 'peak', 'final-Home-60s', 'minimized-60s']:
        comparison[point] = {}
        for metric in metrics:
            before = statistics.median(r[point][metric] for r in baseline['runs'])
            after = statistics.median(r[point][metric] for r in runs)
            comparison[point][metric] = {
                'baselineMedianBytes': before, 'currentMedianBytes': after,
                'reductionPercent': (before - after) * 100 / before}
    result = {'status': 'verified', 'runs': runs, 'samples': len(samples),
              'csvRows': len(rows), 'comparison': comparison,
              'baselineSummary': str(args.baseline_summary),
              'checks': ['exact recipe order', 'three distinct app lifetimes',
                         'minimum prescribed waits', 'app and helper identity rows',
                         'positive metrics', 'per-point totals', 'CSV/JSON agreement',
                         'active-page text and screenshot artifacts'],
              'limitations': ['transient helpers between samples are not measured',
                              'working-set and counter reads are sequential snapshots',
                              'other applications and GPU/system allocations are excluded',
                              'focus samples follow minimize and do not isolate its effects',
                              'peak excludes the two additional focus samples',
                              'baseline summary is reused without rerunning the baseline']}
    (args.root / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
