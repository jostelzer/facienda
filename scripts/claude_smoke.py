#!/usr/bin/env python3
"""Exercise the bundled helper's Claude runner and task-session commands with an isolated database.

Plays the parts of the Claude runner session and one Claude task session through their environment,
the way the Claude app identifies them. Opens no app and touches no personal data.
"""
import argparse
import json
import os
import pathlib
import sqlite3
import subprocess
import tempfile
import uuid
from datetime import datetime, timezone

parser = argparse.ArgumentParser()
parser.add_argument('--helpers', type=pathlib.Path, default=pathlib.Path('build/Build/Products/Release/Facienda.app/Contents/Helpers'))
args = parser.parse_args()
# Helpers make and open libraries in the system temp folder only for tests that say so.
os.environ['FACIENDA_TEST_LIBRARY'] = '1'
directory = pathlib.Path(tempfile.mkdtemp(prefix='facienda-claude-smoke-'))
database = directory / 'facienda.sqlite'
helper_path = str(args.helpers.resolve() / 'facienda-mcp')
subprocess.run([helper_path, '--database', str(database), '--init'], capture_output=True, text=True, timeout=10, check=True)
RUNNER, WORKER, OTHER = 'local_smoke-runner', 'local_smoke-worker', 'local_smoke-other'
CLI = str(uuid.uuid4())


def run(*arguments, session=None, cli=None, check=True, timeout=15):
    environment = {key: value for key, value in os.environ.items() if not key.startswith('CLAUDE_CODE_')}
    if session:
        environment['CLAUDE_CODE_HOST_SESSION_ID'] = session
    if cli:
        environment['CLAUDE_CODE_SESSION_ID'] = cli
    result = subprocess.run([helper_path, '--database', str(database), *arguments], text=True, capture_output=True,
                            timeout=timeout, env=environment, cwd=directory)
    if check:
        assert result.returncode == 0, (arguments, result.stderr)
    return result


def as_json(result):
    return json.loads(result.stdout)


# A task chosen with a Claude model, created through the same MCP tool API sessions use.
arguments = directory / 'task.json'
arguments.write_text(json.dumps({'title': 'Draft the venue email', 'nextAction': 'Write the draft', 'returnAt': '2030-01-01T12:00:00Z'}))
created = as_json(run('--call', 'facienda_task_create', '--arguments-file', str(arguments)))
task_id, task_handle = created['id'], created['handle']
with sqlite3.connect(database) as db:
    db.execute("UPDATE tasks SET workerModel = 'claude-sonnet-5-5', workerReasoningEffort = 'medium', workerProvider = 'claude', cwd = ? WHERE id = ?",
               (str(directory / 'Work' / task_id), task_id))
(directory / 'Work' / task_id).mkdir(parents=True)

# One-time setup: the session that sends the prepared request binds itself as the runner.
setup = as_json(run('--claude', 'prepare-setup', '--runner-folder', str(directory / 'runners')))
assert setup['url'].startswith('claude://code/new?') and setup['challenge'] in setup['prompt']
assert run('--claude', 'bind', '--challenge', setup['challenge'], check=False).returncode != 0, 'bind needs the Claude session ID'
assert run('--claude', 'bind', '--challenge', 'stale', session=RUNNER, check=False).returncode != 0
instructions = run('--claude', 'bind', '--challenge', setup['challenge'], session=RUNNER).stdout
assert 'run_in_background' in instructions and '--claude watch' in instructions and 'set_session_model' in instructions
assert len(instructions.encode()) < 12000
assert run('--claude', 'bind', '--challenge', setup['challenge'], session=OTHER, check=False).returncode != 0
run('--claude', 'capabilities', '--can-start-sessions', 'false', session=RUNNER)
assert run('--claude', 'instructions', session=OTHER, check=False).returncode != 0
# The runner's folder lets it run only its relay commands; nothing there reaches tools or other modes.
runner_settings = json.loads(next((directory / 'runners').glob('runner-*/.claude/settings.local.json')).read_text())
assert all('--call' not in rule and '--runner' not in rule and not rule.endswith("facienda-mcp *)") for rule in runner_settings['permissions']['allow'])

# Starting the task: the Codex runner never sees it; the app hands it to Claude's composer.
# No helper command queues work: the start goes in as the app records the user's Start.
assert 'Unknown runner command' in run('--runner', 'enqueue', '--task-id', task_id, check=False).stderr
start = {'id': str(uuid.uuid4()).upper()}
with sqlite3.connect(database) as db:
    db.execute("INSERT INTO dispatches(id, taskId, state, requestedAt, kind) VALUES (?, ?, 'queued', ?, 'start')",
               (start['id'], task_id, datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S.000')))
    assert db.execute('SELECT provider FROM dispatches WHERE id = ?', (start['id'],)).fetchone()[0] == 'claude'

handoff = as_json(run('--claude', 'handoff', '--dispatch-id', start['id']))
assert handoff['url'].startswith('claude://code/new?') and handoff['prompt'].startswith(f"Facienda dispatch: {start['id']}\n")
assert f"--claude attach --dispatch-id {start['id']}" in handoff['prompt']
assert as_json(run('--claude', 'next', session=RUNNER)) == {'status': 'idle'}

# The task session links itself and waits while the runner applies the model.
attached = run('--claude', 'attach', '--dispatch-id', start['id'], session=WORKER, cli=CLI).stdout
assert '--claude await' in attached and 'Sonnet 5.5' in attached and 'Medium' in attached, attached
assert 'already runs in another' in run('--claude', 'attach', '--dispatch-id', start['id'], session=OTHER, check=False).stderr
assert run('--claude', 'attach', '--dispatch-id', start['id'], session=RUNNER, check=False).returncode != 0
assert as_json(run('--claude', 'watch', '--seconds', '3', session=RUNNER))['status'] == 'work'
job = as_json(run('--claude', 'next', session=RUNNER))
assert job['type'] == 'configure' and job['threadId'] == WORKER and job['model'] == 'claude-sonnet-5-5' and job['effort'] == 'medium', job
assert job['needsTitle'] is True and job['originalRequest'] == 'Draft the venue email'
# The user sent this start by hand, so the settings job brings none to send.
assert job['start'] is None, job
title_file = directory / 'title.json'
title_file.write_text(json.dumps({'displayTitle': 'Venue email draft'}))
assert as_json(run('--claude', 'name', '--task-id', task_id, '--title-file', str(title_file), session=RUNNER))['displayTitle'] == 'Venue email draft'
run('--claude', 'configured', '--thread-id', WORKER, '--applied', 'true', '--note', 'Sonnet 5.5, medium', session=RUNNER)
waited = run('--claude', 'await', '--dispatch-id', start['id'], '--seconds', '5', session=WORKER).stdout
assert 'settings are applied' in waited and '--claude prompt' in waited
prompt = run('--claude', 'prompt', '--dispatch-id', start['id'], session=WORKER).stdout
assert prompt.startswith(f"Facienda dispatch: {start['id']}\n") and 'Claude session' in prompt and '--tools' in prompt
assert 'native Codex chat' not in prompt and 'app-server' not in prompt
assert f'TASK HANDLE: {task_handle}' in prompt
assert run('--claude', 'prompt', '--dispatch-id', start['id'], session=OTHER, check=False).returncode != 0
# A session cannot claim another's identity on the command line.
assert run('--claude', 'prompt', '--dispatch-id', start['id'], '--session-id', WORKER, session=OTHER, check=False).returncode != 0
tools = as_json(run('--tools'))
assert any(tool['name'] == 'facienda_save_result' for tool in tools)

# A reply from Facienda reaches the owning session through the runner.
reply_id = str(uuid.uuid4()).upper()
now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S.000')
with sqlite3.connect(database) as db:
    db.execute("INSERT INTO dispatches(id, taskId, state, requestedAt, threadId, kind, message) VALUES (?, ?, 'queued', ?, ?, 'reply', 'Make it shorter')",
               (reply_id, task_id, now, WORKER))
    assert db.execute('SELECT provider FROM dispatches WHERE id = ?', (reply_id,)).fetchone()[0] == 'claude'
assert as_json(run('--claude', 'watch', '--seconds', '3', session=RUNNER))['status'] == 'work'
job = as_json(run('--claude', 'next', session=RUNNER))
assert job['type'] == 'deliver' and job['threadId'] == WORKER and job['message'].startswith(f'Facienda dispatch: {reply_id}\n'), job
run('--claude', 'begin', '--dispatch-id', reply_id, session=RUNNER)
run('--claude', 'ack', '--dispatch-id', reply_id, session=RUNNER)
follow_up = run('--claude', 'prompt', '--dispatch-id', reply_id, session=WORKER).stdout
# A chat that already holds Facienda's instructions gets the user's words up front, with a way back to the full rules.
assert follow_up.startswith(f'Facienda dispatch: {reply_id}\n') and '\nMake it shorter\n' in follow_up and f'facienda_task_instructions, taskId {task_handle}' in follow_up, follow_up
# The full instructions come back through the task's handle only, never by dispatch ID alone.
full = as_json(run('--call', 'facienda_task_instructions', '--arguments', json.dumps({'taskId': task_handle, 'dispatchId': start['id']})))
assert full.startswith(f"Facienda dispatch: {start['id']}\n") and f'TASK HANDLE: {task_handle}' in full
assert run('--call', 'facienda_task_instructions', '--arguments', json.dumps({'taskId': task_id}), check=False).returncode != 0
assert as_json(run('--claude', 'next', session=RUNNER)) == {'status': 'idle'}
status = as_json(run('--claude', 'status'))
assert status['runner']['sessionId'] == RUNNER and status['sessions'][0]['configureState'] == 'done' and status['queue'] == []
with sqlite3.connect(database) as db:
    assert db.execute('SELECT provider, codexThreadId FROM threadLinks WHERE taskId = ?', (task_id,)).fetchall() == [('claude', WORKER)]
    assert db.execute('SELECT displayTitle FROM tasks WHERE id = ?', (task_id,)).fetchone()[0] == 'Venue email draft'

# A session the app had Claude adopt: its start comes with its settings, so the runner sends it straight after them.
IMPORTED = 'local_smoke-imported'
arguments.write_text(json.dumps({'title': 'Plan the venue seating', 'nextAction': 'Plan it', 'returnAt': '2030-01-01T12:00:00Z'}))
second = as_json(run('--call', 'facienda_task_create', '--arguments-file', str(arguments)))['id']
first_start = str(uuid.uuid4()).upper()
now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S.000')
with sqlite3.connect(database) as db:
    db.execute("UPDATE tasks SET workerModel = 'claude-opus-5-5', workerReasoningEffort = 'high', workerProvider = 'claude' WHERE id = ?", (second,))
    db.execute("INSERT INTO dispatches(id, taskId, state, requestedAt, threadId, kind) VALUES (?, ?, 'queued', ?, ?, 'start')", (first_start, second, now, IMPORTED))
    db.execute("INSERT INTO threadLinks(id, taskId, codexThreadId, role, linkedBy, title, preview, lastKnownStatus, statusSource, statusVerified, provider) "
               "VALUES (?, ?, ?, 'work', 'Facienda', 'Plan the venue seating', '', 'unknown', 'app', 0, 'claude')", (str(uuid.uuid4()), second, IMPORTED))
    db.execute("INSERT INTO claudeSessions(threadId, taskId, linkedAt, model, effort, fast, configureState) VALUES (?, ?, ?, 'claude-opus-5-5', 'high', 0, 'pending')",
               (IMPORTED, second, now))
assert as_json(run('--claude', 'watch', '--seconds', '3', session=RUNNER))['status'] == 'work'
job = as_json(run('--claude', 'next', session=RUNNER))
assert job['type'] == 'configure' and job['threadId'] == IMPORTED and job['model'] == 'claude-opus-5-5', job
assert job['start']['dispatchId'] == first_start and job['start']['threadId'] == IMPORTED, job
assert job['start']['message'].startswith(f'Facienda dispatch: {first_start}\n') and f'--claude prompt --dispatch-id {first_start}' in job['start']['message'], job
assert f'--claude ack --dispatch-id {first_start}' in job['next'], job
# Begun already: the task session can read it as soon as the message lands, and nothing offers it twice.
assert f'Facienda dispatch: {first_start}\n' in run('--claude', 'prompt', '--dispatch-id', first_start, session=IMPORTED).stdout
assert as_json(run('--claude', 'next', session=RUNNER)) == {'status': 'idle'}
# A runner on older instructions reports the settings first and hears that the start is still its to send.
reported = as_json(run('--claude', 'configured', '--thread-id', IMPORTED, '--applied', 'true', '--note', 'Opus 5.5, high', session=RUNNER))
assert reported['start']['dispatchId'] == first_start and f'--claude ack --dispatch-id {first_start}' in reported['next'], reported
run('--claude', 'ack', '--dispatch-id', first_start, session=RUNNER)
assert as_json(run('--claude', 'configured', '--thread-id', IMPORTED, '--applied', 'true', session=RUNNER)) == {'status': 'ok'}
with sqlite3.connect(database) as db:
    assert db.execute('SELECT state FROM dispatches WHERE id = ?', (first_start,)).fetchone()[0] == 'started'
assert as_json(run('--claude', 'next', session=RUNNER)) == {'status': 'idle'}
print(json.dumps({'claudeSetup': 'passed', 'composerHandoff': 'passed', 'sessionLink': 'passed', 'modelConfiguration': 'passed',
                  'replyRelay': 'passed', 'adoptedStart': 'passed', 'database': str(database)}, indent=2))
