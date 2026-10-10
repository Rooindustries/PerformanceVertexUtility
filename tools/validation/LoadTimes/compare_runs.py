import csv
import statistics
import sys
from pathlib import Path


def load(folder):
    rows = {}
    with open(Path(folder) / 'loadtimes.csv', encoding='utf-8-sig') as handle:
        for row in csv.DictReader(handle):
            rows.setdefault((row['page'], row['visit']), []).append(row)
    return rows


def median(rows, field):
    if rows and (field not in rows[0] or (field == 'state_ms' and all(row[field] in ('', None) for row in rows))):
        field = 'complete_ms'
    values = [float(row[field]) for row in rows if row[field] not in ('', None)]
    failed = len(rows) - len(values)
    if not values:
        return 'timeout', failed
    return str(int(statistics.median(values))), failed


def memory(folder):
    path = Path(folder) / 'memory.csv'
    if not path.exists():
        return []
    with open(path, encoding='utf-8-sig') as handle:
        return list(csv.DictReader(handle))


def main(before, after, output):
    old, new = load(before), load(after)
    keys = list(dict.fromkeys(list(old) + list(new)))
    lines = ['| page | visit | usable before | usable after | state before | state after | complete before | complete after | timeouts before/after |', '|---|---|---|---|---|---|---|---|---|']
    for key in keys:
        a_rows, b_rows = old.get(key, []), new.get(key, [])
        ub, fb = median(a_rows, 'usable_ms') if a_rows else ('-', 0)
        ua, _ = median(b_rows, 'usable_ms') if b_rows else ('-', 0)
        sb, _ = median(a_rows, 'state_ms') if a_rows else ('-', 0)
        sa, _ = median(b_rows, 'state_ms') if b_rows else ('-', 0)
        cb, fb = median(a_rows, 'complete_ms') if a_rows else ('-', 0)
        ca, fa = median(b_rows, 'complete_ms') if b_rows else ('-', 0)
        lines.append(f'| {key[0]} | {key[1]} | {ub} | {ua} | {sb} | {sa} | {cb} | {ca} | {fb}/{fa} |')
    lines += ['', '| run | tour | when | private MB | working set MB | app CPU ms |', '|---|---|---|---|---|---|']
    for name, folder in (('before', before), ('after', after)):
        for row in memory(folder):
            lines.append(f"| {name} | {row['tour']} | {row['when']} | {row['private_mb']} | {row['working_set_mb']} | {row['cpu_ms']} |")
    Path(output).write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print('\n'.join(lines))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3])
