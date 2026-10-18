#!/usr/bin/env python3
"""Compare one and four memory batches on identical invented evidence using the chosen background model.

This spends real model calls. Pass the provider/model from Settings; both libraries and receipts stay in system temp.
The end-to-end time includes retrieval, independent evidence review, conflict reconciliation and final abstraction.
"""
import argparse
import json
import os
import signal
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time

SUBJECTS = {
    'greenhouse': [
        'Our greenhouse protocol starts by checking the sensor against a dry reference before each batch.',
        'We retired the water reference because evaporation changed its baseline.',
        'A reference error above two units means stop and recalibrate before measuring plants.',
        'Use the same instrument for the reference and plant readings so their drift is comparable.',
        'Wait ten minutes after switching on the greenhouse sensor before testing the reference.',
        'Record the reference value beside every batch so later comparisons can account for drift.',
        'Keep the dry reference sealed between checks; humidity changes the material.',
        'Label replacement references with their calibration date to avoid mixing versions.',
        'A plant response is only interpretable after the baseline check passes.',
        'Last month a skipped reference check made instrument drift look like plant growth.',
        'Our greenhouse stopping rule applies to measurements, not to watering or routine cleaning.',
        'We have not yet measured the yield of the latest greenhouse batch.',
    ],
    'book covers': [
        'Our small studio approves a book cover composition before choosing typography.',
        'We lost a day polishing lettering on a layout that was later rejected.',
        'Make three rough composition sketches before rendering a full cover.',
        'Judge hierarchy with the cover reduced to its bookstore thumbnail size.',
        'The author chooses a composition before the studio begins detailed lettering.',
        'Test the chosen type at actual print size because screen zoom hides legibility problems.',
        'Check title contrast on both the light and dark parts of the illustration.',
        'Keep the spine title within the printer template and check the page-count-dependent width.',
        'Proofread the final author name and title against the signed manuscript.',
        'Export the cover only after layout, lettering and spelling have been approved.',
        'This review sequence is for finished book covers; quick internal sketches need no approval.',
        'The last cover review caught unreadable small text before we exported.',
    ],
    'reading-room shelves': [
        'For the reading-room shelves, compare wood samples against the floor in the actual room.',
        'We chose birch because the oak sample looked too dark under our evening light.',
        'Catalogue swatches were misleading; inspect finishes where the furniture will stand.',
        'Measure the wall at floor and ceiling height before ordering the shelf boards.',
        'Leave space for the skirting board so the upright can sit flat against the wall.',
        'Check the wall construction before selecting shelf anchors.',
        'Use the anchor manufacturer load rating and account for the expected book weight.',
        'Locate pipes and wires before drilling any shelf mounting holes.',
        'Make a cardboard shelf outline to check that the door can still open.',
        'Order the reading-room boards only after dimensions and the finish sample are approved.',
        'We have approved the birch sample but have not reported installing the shelves.',
        'These finish choices concern the reading room and do not set the style for every room.',
    ],
    'pottery glazing': [
        'Our pottery group tests a glaze on a tile before applying it to a finished bowl.',
        'Use a tile made from the same clay body as the bowl because the fired colour depends on both.',
        'Record glaze batch, clay body and firing temperature on the test tile label.',
        'Keep the application thickness consistent between tile and bowl.',
        'Allow the glazed tile to dry fully before putting it in the kiln.',
        'Place a witness cone beside the tiles to check the heat work reached during firing.',
        'Record the cooling schedule because it changes the surface finish of this glaze.',
        'Inspect the cooled tile for crazing and pinholes before choosing it for the bowl.',
        'We rejected the thick application because the test tile developed pinholes.',
        'The thinner tile passed our visual review; we have not fired the finished bowl yet.',
        'A visual glaze test does not establish that a vessel is safe for food contact.',
        'Keep failed glaze tiles too, with their labels, so we can compare future trials.',
    ],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helpers', type=Path, default=Path('.build/debug'))
    parser.add_argument('--provider', required=True, choices=['codex', 'claude'])
    parser.add_argument('--model', required=True)
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix='facienda-memory-parallelism-'))
    helper = str((args.helpers / 'facienda-mcp').resolve())
    environment = dict(os.environ, FACIENDA_TEST_LIBRARY='1')
    print(json.dumps({'directory': str(root), 'provider': args.provider, 'model': args.model}), flush=True)
    results = []
    for parallelism in (1, 4):
        database = root / f'workers-{parallelism}.sqlite'
        command = [helper, '--database', str(database)]
        subprocess.run(command + ['--init'], env=environment, check=True, capture_output=True)
        with sqlite3.connect(database) as connection:
            space = connection.execute('SELECT id FROM memorySpaces ORDER BY position LIMIT 1').fetchone()[0]
            connection.execute('UPDATE memorySettings SET enabled=1,useAIWorker=1')
            connection.execute('INSERT INTO serviceModel VALUES (1,?,?,?)', (args.provider, args.model, '2026-01-01 00:00:00'))
            for group, (subject, statements) in enumerate(SUBJECTS.items()):
                for index, statement in enumerate(statements):
                    connection.execute('INSERT INTO memoryUtterances(id,spaceId,text,source,sourceKind,at) VALUES (?,?,?,?,?,?)',
                                       (f'invented-{group}-{index}', space, statement, f'Invented {subject} conversation {index}',
                                        'userReply', f'2026-01-{group+1:02} 12:{index:02}:00'))
        started = time.monotonic()
        peak = 0
        workers = set()
        with (root / f'workers-{parallelism}.json').open('w') as output, (root / f'workers-{parallelism}.log').open('w') as errors:
            process = subprocess.Popen(command + ['--runner', 'memory-understand', '--space', space, '--batches', '4',
                                                  '--parallelism', str(parallelism)], env=environment, stdout=output, stderr=errors, start_new_session=True)
            while process.poll() is None:
                processes = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,comm='], text=True)
                running = [line.split(None, 2)[0] for line in processes.splitlines()
                           if len(line.split(None, 2)) == 3 and line.split(None, 2)[1] == str(process.pid)
                           and line.split(None, 2)[2].endswith('/facienda-memory')]
                workers.update(running)
                peak = max(peak, len(running))
                if time.monotonic() - started > 2400:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait()
                    raise TimeoutError(f'Benchmark exceeded 40 minutes; evidence retained at {root}')
                time.sleep(0.2)
        assert process.returncode == 0, (root / f'workers-{parallelism}.log').read_text()
        progress = json.loads((root / f'workers-{parallelism}.json').read_text())
        assert progress['processed'] == 48 and progress['pending'] == 0 and progress['retrying'] == 0, progress
        with sqlite3.connect(database) as connection:
            rows = connection.execute('SELECT kind,subject,summary,model,citations FROM memoryUnderstanding').fetchall()
            assert len(rows) >= 4 and all(row[3] == args.model and json.loads(row[4]) for row in rows), rows
            (root / f'understanding-{parallelism}.json').write_text(json.dumps(rows, indent=2))
            # A total count can hide a skipped subject behind a newly-created cross-subject pattern.
            represented = set()
            for kind, _, _, _, citations in rows:
                if kind != 'process':
                    continue
                for citation in json.loads(citations):
                    source = connection.execute('SELECT source FROM memoryEvidence WHERE id = ?', (citation['evidenceId'],)).fetchone()
                    represented.update(subject for subject in SUBJECTS if source and f'Invented {subject} conversation' in source[0])
            assert represented == set(SUBJECTS), {'missingProcesses': sorted(set(SUBJECTS) - represented), 'directory': str(root)}
        result = {'parallelism': parallelism, 'seconds': round(time.monotonic() - started, 2), 'peakWorkerCalls': peak,
                  'workerCalls': len(workers), 'processed': progress['processed'], 'understandings': len(rows)}
        assert peak == parallelism, result
        results.append(result)
        print(json.dumps(result), flush=True)
    report = {'runs': results, 'speedup': round(results[0]['seconds'] / results[1]['seconds'], 2)}
    (root / 'comparison.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
