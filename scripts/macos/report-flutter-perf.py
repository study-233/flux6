#!/usr/bin/env python3
"""Build per-run and per-cell CSV from the archived unrounded timing data."""
import argparse
import csv
import itertools
import json
from pathlib import Path
import statistics

DEFAULT_OUT = Path(__file__).resolve().parents[2] / 'docs/compose/audits/2026-11-07-p5-p6/performance'
CELL_KEYS = ('width', 'nodes', 'online', 'stage')
CELL_METRICS = ('launchReadyMs', 'mainp95', 'mainmax', 'mainOver50', 'cvp95',
                'uip95', 'rasterp95', 'uiOverBudgetPct', 'rasterOverBudgetPct')


def duration_metrics(name, values, budget):
    ordered = sorted(values)
    result = {name + 'N': len(values), name + 'Over50': sum(x > 50_000 for x in values)}
    for suffix, p in [('p50', .5), ('p95', .95), ('max', 1)]:
        rank = int((len(values) - 1) * p)
        result[name + suffix] = round(ordered[rank] / 1000, 3) if values else None
    above = sum(x > budget for x in values)
    result[name + 'OverBudgetPct'] = round(100 * above / len(values), 2) if values else None
    return result


def summarize_run(doc):
    ready = doc['ready']
    hz = ready['display']['maximumHz']
    for name, stage in doc['stages'].items():
        row = dict(round=doc['round'], width=doc['width'], nodes=doc['nodes'],
                   online=int(doc['online']), stage=name, thermal=stage['thermal'], hz=hz,
                   launchReadyMs=round(ready['launchToReadyMs'], 2),
                   durationMs=round(stage['durationUs'] / 1000, 2))
        samples = {'main': stage['mainUs'], 'cv': stage['cvUs']}
        for i, phase in enumerate(('ui', 'raster', 'total'), start=1):
            samples[phase] = [frame[i] for frame in stage['frameUs']]
        for phase, values in samples.items():
            row.update(duration_metrics(phase, values, 1_000_000 / hz))
        yield row


def cell_key(row):
    return tuple(row[field] for field in CELL_KEYS)


def summarize_cells(runs):
    for key, values in itertools.groupby(sorted(runs, key=cell_key), key=cell_key):
        rounds = list(values)
        cell = dict(zip(CELL_KEYS, key))
        cell['rounds'] = len(rounds)
        for name in CELL_METRICS:
            data = [row[name] for row in rounds if row[name] is not None]
            cell[name] = round(statistics.median(data), 3) if data else None
        yield cell


def write(path, rows):
    with path.open('w', newline='') as output:
        writer = csv.DictWriter(output, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path, nargs='?', default=DEFAULT_OUT)
    directory = parser.parse_args().directory
    runs = []
    for file in sorted((directory / 'raw').glob('*.json')):
        runs.extend(summarize_run(json.loads(file.read_text())))
    if not runs:
        raise SystemExit(f'No raw samples in {directory}')
    write(directory / 'runs.csv', runs)
    write(directory / 'cells.csv', list(summarize_cells(runs)))


if __name__ == '__main__':
    main()
