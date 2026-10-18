#!/usr/bin/env python3
"""Exercise native understanding with the real configured worker on invented data only.

Pass the provider/model selected in Settings. Results stay in a new system-temp library.
This is intentionally separate from offline tests: it spends model calls and requires login.
"""
import argparse
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--helpers', type=Path, default=Path('.build/debug'))
parser.add_argument('--provider', required=True, choices=['codex', 'claude'])
parser.add_argument('--model', required=True)
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix='facienda-understanding-eval-'))
database = root / 'evaluation.sqlite'
environment = dict(os.environ, FACIENDA_TEST_LIBRARY='1')
helper = str((args.helpers / 'facienda-mcp').resolve())

def run(*arguments):
    result = subprocess.run([helper, '--database', str(database), *arguments], env=environment,
                            capture_output=True, text=True, timeout=2400)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return None if '--init' in arguments else json.loads(result.stdout)

run('--init')
connection = sqlite3.connect(database)
space = connection.execute('SELECT id FROM memorySpaces ORDER BY position LIMIT 1').fetchone()[0]
connection.execute('UPDATE memorySettings SET enabled=1,useAIWorker=1')
connection.execute('INSERT INTO serviceModel VALUES (1,?,?,?)', (args.provider, args.model, '2026-01-01 00:00:00'))
examples = [
    'For the greenhouse experiments, calibrate the sensor against the water reference before each batch. If the reference drifts, stop and recalibrate before interpreting plant changes.',
    'Yesterday we skipped the greenhouse reference check and mistook sensor drift for a plant response. Checking the baseline first would have separated instrument error from biology.',
    'For the studio book covers, agree on the composition before choosing typography. Last time we spent a day on lettering and then changed the whole layout.',
    'The next cover review worked: composition first, lettering at actual size second, export last. We caught unreadable small text before exporting.',
    'For our reading-room shelves, compare wood samples against the floor in the actual room before ordering. We selected birch after seeing that the oak looked too dark there.',
    'The reading-room shelf sample review saved a wrong order. Context matters for finishes; a catalogue swatch was misleading under our evening light.',
    'I want previews and evidence before committing expensive work in the studio and renovation. That is a preference for these projects, not a rule for every quick sketch.',
    'New greenhouse protocol: use the dry reference instead of the water reference from now on. Water evaporated and changed the baseline. Check the dry reference before each batch; the stopping rule stays.',
]
for i, text in enumerate(examples[:-1]):
    connection.execute('INSERT INTO memoryUtterances(id,spaceId,text,source,sourceKind,at) VALUES (?,?,?,?,?,?)',
                       (f'invented-{i}', space, text, f'Invented conversation {i+1}', 'userReply', f'2026-01-{i+1:02} 12:00:00'))
connection.commit()
print(json.dumps({'directory': str(root), 'model': args.model}), flush=True)
progress = run('--runner', 'memory-understand', '--space', space, '--batches', '4')
(root / 'learning.json').write_text(json.dumps(progress, indent=2))
print(json.dumps({'learning': progress}), flush=True)
assert progress['pending'] == 0 and progress['processed'] == len(examples) - 1, progress
# A later correction must revise existing understanding, not create an unrelated competing rule.
connection.execute('INSERT INTO memoryUtterances(id,spaceId,text,source,sourceKind,at) VALUES (?,?,?,?,?,?)',
                   ('invented-correction', space, examples[-1], 'Invented later correction', 'userReply', '2026-02-01 12:00:00'))
connection.commit()
progress = run('--runner', 'memory-understand', '--space', space, '--batches', '4')
print(json.dumps({'afterCorrection': progress}), flush=True)
assert progress['pending'] == 0 and progress['processed'] == len(examples), progress
assert connection.execute('SELECT count(*) FROM memoryUnderstandingHistory').fetchone()[0] > 0
rows = [dict(zip([c[0] for c in cursor.description], row)) for cursor in [connection.execute('SELECT kind,subject,summary,steps,citations,confidence FROM memoryUnderstanding')] for row in cursor.fetchall()]
(root / 'understanding.json').write_text(json.dumps(rows, indent=2))
assert any(r['kind'] == 'process' and len(json.loads(r['steps'])) >= 2 for r in rows), rows
assert all(r['summary'] not in examples for r in rows), 'The worker merely copied a source'
questions = [
    'How should we prepare the next greenhouse measurement batch? Which reference is current, and why?',
    'What shared lesson connects the studio cover reviews and reading-room shelf choices? Where does that lesson stop applying?',
    'Did the latest greenhouse batch succeed, and what was its yield?',
]
answers = []
for i, question in enumerate(questions):
    answer = run('--runner', 'memory-reflect', '--space', space, '--query', question)
    answers.append(answer)
    (root / f'answer-{i+1}.json').write_text(json.dumps(answer, indent=2))
    print(json.dumps({'question': question, 'answer': answer['answer'], 'nextMove': answer['nextMove'], 'calls': answer['calls'], 'citations': len(answer['citations'])}), flush=True)
    assert answer['model'] == args.model
assert 'dry' in answers[0]['answer'].lower() and answers[0]['citations'], answers[0]
assert answers[1]['citations'] and len({c['evidenceId'] for c in answers[1]['citations']}) >= 2, answers[1]
assert answers[2]['uncertainties'] and not answers[2]['nextMove'], answers[2]
print('Real-worker evaluation passed; inspect the retained answers for semantic quality.', flush=True)
