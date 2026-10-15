#!/usr/bin/env python3
"""Exercise actual bundled stdio MCP and hook executables with an isolated database.

No Codex registration, app activation, or personal database changes.
"""
import argparse
import json
import os
import pathlib
import re
import selectors
import sqlite3
import subprocess
import tempfile
import time
import threading
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from datetime import datetime, timedelta, timezone

parser = argparse.ArgumentParser()
parser.add_argument('--helpers', type=pathlib.Path, default=pathlib.Path('build/Build/Products/Release/Facienda.app/Contents/Helpers'))
parser.add_argument('--workspace', action='store_true', help='Exercise the library folder the helpers find on their own')
args = parser.parse_args()
# Helpers make and open libraries in the system temp folder only for tests that say so.
os.environ['FACIENDA_TEST_LIBRARY'] = '1'
directory = pathlib.Path(tempfile.mkdtemp(prefix='facienda-smoke-'))
library = directory
database = library / 'facienda.sqlite'
# Helpers never make a library: only an explicit --init does.
missing = subprocess.run([str(args.helpers / 'facienda-mcp'), '--database', str(database), '--call', 'task_search', '--arguments', '{"query":""}'], capture_output=True, text=True, timeout=5)
assert missing.returncode != 0 and 'missing' in missing.stderr and not database.exists(), missing.stderr
subprocess.run([str(args.helpers / 'facienda-mcp'), '--database', str(database), '--init'], capture_output=True, text=True, timeout=10, check=True)
helper_arguments = ['--library-folder', str(library)] if args.workspace else ['--database', str(database)]
process = subprocess.Popen([str(args.helpers / 'facienda-mcp'), *helper_arguments], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
sequence = 0

def request(method, params):
    global sequence
    sequence += 1
    process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': sequence, 'method': method, 'params': params}) + '\n')
    process.stdin.flush()
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + 10
    try:
        while time.monotonic() < deadline:
            if not selector.select(max(0, deadline - time.monotonic())):
                break
            line = process.stdout.readline()
            if not line:
                status = process.wait(timeout=2)
                details = process.stderr.read().strip()
                raise RuntimeError(f'MCP exited: {status}; helper={args.helpers / "facienda-mcp"}; stderr={details or "(empty)"}')
            value = json.loads(line)
            if value.get('id') == sequence:
                assert 'error' not in value, value
                return value['result']
    finally:
        selector.close()
    raise TimeoutError(method)

def call(name, arguments, error=False):
    result = request('tools/call', {'name': 'facienda_' + name, 'arguments': arguments})
    assert bool(result.get('isError')) == error, result
    text = result['content'][0]['text']
    return text if error else json.loads(text)

try:
    # Real Codex 0.159 handshake: experimental capability values are JSON objects,
    # not strings. This catches the SDK decoder incompatibility found in live use.
    request('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {'experimental': {'codex/auth-change': {}}, 'elicitation': {'form': {}, 'url': {}}}, 'clientInfo': {'name': 'FaciendaSmoke', 'version': '1'}})
    process.stdin.write(json.dumps({'jsonrpc': '2.0', 'method': 'notifications/initialized'}) + '\n')
    process.stdin.flush()
    tools = request('tools/list', {})['tools']
    assert len(tools) == 21
    assert next(tool for tool in tools if tool['name'] == 'facienda_current_task')['annotations']['readOnlyHint'] is True
    assert next(tool for tool in tools if tool['name'] == 'facienda_task_update')['annotations']['readOnlyHint'] is False
    task = call('task_create', {'title': 'Isolated smoke task', 'nextAction': 'Check the report', 'returnAt': '2030-01-01T12:00:00Z'})
    task_id, task_handle = task['id'], task['handle']
    assert task_handle.startswith(task_id + '.')
    # Tools reach a task through its handle only: a bare ID, a forged secret or no task at all is refused.
    assert 'handle' in call('task_update', {'taskId': task_id, 'brief': 'x'}, error=True)
    call('task_update', {'taskId': task_id + '.' + '0' * 32, 'brief': 'x'}, error=True)
    call('task_search', {'query': ''}, error=True)
    call('link_thread', {'taskId': task_handle, 'threadId': 'smoke-thread'})
    assert call('current_task', {'threadId': 'smoke-thread', 'taskId': task_handle})['id'] == task_id
    # A thread ID alone says only that the thread is linked, nothing of the task.
    bare = call('current_task', {'threadId': 'smoke-thread'})
    assert set(bare) == {'linked', 'status'} and bare['linked'] is True and task_id not in json.dumps(bare), bare
    call('current_task', {'threadId': 'smoke-thread', 'taskId': task_id}, error=True)
    assert call('task_search', {'query': 'isolated', 'taskId': task_handle})[0]['id'] == task_id
    call('task_update', {'taskId': task_handle, 'brief': 'Prepared and awaiting review', 'proposedState': 'needsMe'})
    assert call('save_result', {'taskId': task_handle, 'text': 'Native result reporting smoke test'})['saved'] is True
    call('task_update', {'taskId': task_handle, 'proposedState': 'done'}, error=True)
    memory = call('memory_remember', {'text': 'Use an isolated test database', 'source': 'Integration smoke 2026-10-04', 'taskId': task_handle})
    assert not memory.get('confirmedAt') and memory['taskId'] == task_id
    # Current chats name their task; memory is limited to that task's memory.
    assert len(call('memory_recall', {'taskId': task_handle, 'query': ''})) == 1
    assert 'taskId' in next(tool for tool in tools if tool['name'] == 'facienda_memory_recall')['description']
    call('memory_recall', {'workspace': str(directory / 'wrong.sqlite'), 'query': ''}, error=True)
    call('memory_recall', {'query': ''}, error=True)
    call('memory_recall', {'taskId': 'no-such-task', 'query': ''}, error=True)
    call('request_decision', {'taskId': task_handle, 'question': 'Continue?', 'recommendation': 'Review first', 'options': ['Review first', 'Continue']})
    call('schedule_followup', {'taskId': task_handle, 'nextAction': 'Review tomorrow', 'returnAt': '2030-01-02T12:00:00Z'})
    call('propose_completion', {'taskId': task_handle, 'evidence': 'Prepared; user sign-off needed'})

    timings = []
    for event in ['SessionStart', 'UserPromptSubmit', 'Stop']:
        before = time.monotonic()
        hook = subprocess.run([str(args.helpers / 'facienda-hook'), *helper_arguments], input=json.dumps({'session_id': 'smoke-thread', 'hook_event_name': event, 'cwd': '/tmp', 'turn_id': 'smoke-turn'}), text=True, capture_output=True, timeout=2)
        timings.append(round((time.monotonic() - before) * 1000, 2))
        assert hook.returncode == 0
        if event != 'Stop':
            context = json.loads(hook.stdout)['hookSpecificOutput']['additionalContext']
            assert task_handle in context and f'taskId {task_handle}' in context and 'facienda_memory_recall' in context
    for bad in ['not json', '{}']:
        hook = subprocess.run([str(args.helpers / 'facienda-hook'), *helper_arguments], input=bad, text=True, capture_output=True, timeout=2)
        assert hook.returncode == 0 and hook.stdout == ''
    with sqlite3.connect(database) as db:
        assert db.execute('PRAGMA journal_mode').fetchone()[0] == 'wal'
        assert db.execute('SELECT count(*) FROM events WHERE source = ? AND verified = 1', ('mcp',)).fetchone()[0] == 0
        assert db.execute('SELECT state FROM tasks WHERE id = ?', (task_id,)).fetchone()[0] != 'done'
        assert db.execute("SELECT count(*) FROM events WHERE source = 'hook' AND kind LIKE 'hook.%'").fetchone()[0] == 3
        db.execute('BEGIN IMMEDIATE')
        before = time.monotonic()
        hook = subprocess.run([str(args.helpers / 'facienda-hook'), *helper_arguments], input=json.dumps({'session_id': 'smoke-thread', 'hook_event_name': 'Stop'}), text=True, capture_output=True, timeout=2)
        locked_ms = round((time.monotonic() - before) * 1000, 2)
        assert hook.returncode == 0 and locked_ms < 500
        db.rollback()
    if args.workspace:
        # A library that disappears is reported, never replaced: helpers fail, hooks stay quiet, runners retire.
        moved = directory.with_name(directory.name + '-moved')
        library.rename(moved)
        gone = subprocess.run([str(args.helpers / 'facienda-mcp'), *helper_arguments, '--call', 'task_search', '--arguments', '{"query":""}'], capture_output=True, text=True, timeout=5)
        assert gone.returncode != 0 and 'missing' in gone.stderr, gone.stderr
        hook = subprocess.run([str(args.helpers / 'facienda-hook'), *helper_arguments], input=json.dumps({'session_id': 'smoke-thread', 'hook_event_name': 'Stop'}), text=True, capture_output=True, timeout=2)
        assert hook.returncode == 0
        tick = subprocess.run([str(args.helpers / 'facienda-mcp'), *helper_arguments, '--runner', 'tick', '--runner-id', 'smoke-runner'], capture_output=True, text=True, timeout=5)
        assert tick.returncode == 0 and '"retired"' in tick.stdout, tick
        assert not database.exists() and not library.exists()
        moved.rename(library)
        assert call('current_task', {'threadId': 'smoke-thread', 'taskId': task_handle})['id'] == task_id
    # Verify the actual native-dispatch prompt and CLI fallback, not only MCP.
    def helper(*arguments):
        result = subprocess.run([str(args.helpers / 'facienda-mcp'), '--database', str(database), *arguments], text=True, capture_output=True, timeout=5, check=True)
        return json.loads(result.stdout)

    def refused(*arguments, environment=None):
        result = subprocess.run([str(args.helpers / 'facienda-mcp'), *arguments], text=True, capture_output=True, timeout=5, env=environment)
        assert result.returncode != 0, (arguments, result.stdout)
        return result.stderr

    def start(task):
        # The user's Start, as the app records it: no helper command queues work.
        with sqlite3.connect(database) as db:
            db.execute("INSERT INTO dispatches(id, taskId, state, requestedAt, kind) VALUES (?, ?, 'queued', ?, 'start')",
                       (str(uuid.uuid4()).upper(), task, datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S.000')))

    # One mode per command, admin commands that spoke for the user are gone, and only Facienda's libraries are served.
    base = ['--database', str(database)]
    assert 'one of --call' in refused(*base, '--call', 'task_search', '--arguments', '{}', '--runner', 'enqueue', '--task-id', task_id)
    assert 'Unexpected' in refused(*base, '--call', 'task_search', '--arguments', '{}', '--session-id', 'x')
    for command in (['enqueue', '--task-id', task_id], ['answer-approval', '--approval-id', 'x', '--choice', 'allow'], ['rules', '--dispatch-id', 'x'],
                    ['retry-undelivered', '--dispatch-id', 'x', '--confirm-not-delivered', '--evidence-file', '/etc/hosts']):
        assert 'Unknown runner command' in refused(*base, '--runner', *command)
    untested = {key: value for key, value in os.environ.items() if key != 'FACIENDA_TEST_LIBRARY'}
    assert 'serves only' in refused(*base, '--runner', 'status', environment=untested)
    assert 'test libraries only' in refused('--database', str(directory / 'other.sqlite'), '--init', environment=untested)
    assert not (directory / 'other.sqlite').exists()
    (directory / 'notes.sqlite').write_bytes(b'')
    with sqlite3.connect(directory / 'notes.sqlite') as db:
        db.execute('CREATE TABLE notes (text TEXT)')
    assert 'not a Facienda library' in refused('--database', str(directory / 'notes.sqlite'), '--runner', 'status')
    with sqlite3.connect(directory / 'notes.sqlite') as db:
        assert db.execute("SELECT count(*) FROM sqlite_master WHERE name = 'grdb_migrations'").fetchone()[0] == 0
    assert 'only from' in refused(*base, '--call', 'save_result', '--arguments-file', '/etc/hosts')
    linked = directory / 'linked.json'
    linked.symlink_to('/etc/hosts')
    assert 'only from' in refused(*base, '--call', 'save_result', '--arguments-file', str(linked))

    def prepare(delivery):
        receipt = helper('--runner', 'prepare', '--runner-id', 'memory-smoke-runner', '--dispatch-id', delivery['dispatch']['id'])
        assert receipt['state'] == 'claimed' and len(json.dumps(receipt)) < 1000
        saved = json.loads(pathlib.Path(receipt['preparedFile']).read_text())
        return receipt, saved['delivery']

    def begin(delivery):
        receipt, prepared = prepare(delivery)
        result = helper('--runner', 'begin', '--runner-id', 'memory-smoke-runner', '--dispatch-id', delivery['dispatch']['id'], '--prepared-file', receipt['preparedFile'])
        assert len(json.dumps(result)) < 1500 and 'workerPrompt' not in result
        return prepared

    with sqlite3.connect(database) as db:
        db.execute("UPDATE memoryFacts SET confirmedAt = '2026-10-04 12:00:00' WHERE id = ?", (memory['id'],))
    helper('--runner', 'bind', '--thread-id', 'memory-smoke-runner')
    start(task_id)
    instructions = subprocess.run([str(args.helpers / 'facienda-mcp'), '--database', str(database), '--runner', 'instructions'], capture_output=True, text=True, check=True).stdout
    # The runner reads these every heartbeat, so their own text stays small. The quoted helper and library paths
    # repeat in every command and are as long as the folders they sit in, so they count as one short word each.
    paths = re.findall(r"'/[^']*'", instructions)
    assert any(path.endswith("/facienda-mcp'") for path in paths) and any(path.endswith("/facienda.sqlite'") for path in paths), paths
    unpathed = re.sub(r"'/[^']*'", "'PATH'", instructions)
    assert len(unpathed.encode()) < 11000 and '--prepared-file' in instructions, (len(unpathed.encode()), len(instructions.encode()))
    assert 'limit 100' not in instructions
    memory_requests = []

    class MemoryFixture(BaseHTTPRequestHandler):
        def do_POST(self):
            memory_requests.append(self.path)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{}')
        do_PUT = do_POST
        do_PATCH = do_POST
        do_GET = do_POST
        def log_message(self, *args):
            pass

    class MemoryServer(HTTPServer):
        def get_request(self):
            connection = super().get_request()
            memory_requests.append("TCP connection")
            return connection

    # Queue wakeup must not even initiate a TLS connection to memory.
    server = MemoryServer(('127.0.0.1', 0), MemoryFixture)
    serving = threading.Thread(target=server.serve_forever, daemon=True)
    serving.start()
    try:
        helper('--runner', 'memory-configure', '--engine', 'hindsight', '--endpoint', f'https://127.0.0.1:{server.server_port}', '--enabled', 'true')
        before = time.monotonic()
        delivery = helper('--runner', 'wait', '--runner-id', 'memory-smoke-runner', '--seconds', '1')
        queue_ms = round((time.monotonic() - before) * 1000, 2)
        assert queue_ms < 2000 and not memory_requests, (queue_ms, memory_requests)
    finally:
        helper('--runner', 'memory-configure', '--enabled', 'false')
        server.shutdown()
        serving.join(timeout=2)
        server.server_close()
    assert 'workerPrompt' not in delivery and len(json.dumps(delivery)) < 4000
    _, prepared = prepare(delivery)
    prompt = prepared['workerPrompt']
    assert str(database) in prompt and 'facienda_memory_recall' in prompt and 'facienda_memory_remember' in prompt and f'TASK HANDLE: {task_handle}' in prompt
    assert 'Use an isolated test database' in prompt and 'CONFIRMED PERSONAL MEMORY SNAPSHOT' in prompt and 'MEMORY: Personal' in prompt
    arguments_file = directory / 'recall.json'
    arguments_file.write_text(json.dumps({'taskId': task_handle, 'query': ''}))
    assert len(helper('--call', 'facienda_memory_recall', '--arguments-file', str(arguments_file))) == 1
    # New work cannot bypass discovery. Preserve a known owner and attach a
    # background reference without creating another ownership link.
    try:
        helper('--runner', 'begin', '--runner-id', 'memory-smoke-runner', '--dispatch-id', delivery['dispatch']['id'])
        raise AssertionError('Delivery unexpectedly bypassed chat discovery')
    except subprocess.CalledProcessError as error:
        assert 'prepare' in error.stderr
        assert helper('--runner', 'status')['dispatches'][-1]['state'] == 'claimed'
    receipt = {
        'contextKey': delivery['discovery']['contextKey'], 'searchStatus': 'complete',
        'searchSummary': 'Inspected two isolated fixture chats; no external history was searched.',
        'route': 'reuse', 'project': None,
        'chats': [
            {'threadId': 'smoke-thread', 'title': 'Owning fixture', 'projectId': None, 'hostId': 'local',
             'role': 'owner', 'status': 'idle', 'relevance': 'Existing owner of the fixture task',
             'evidence': [{'sourceReference': 'fixture turn 1', 'excerpt': delivery['task']['title'], 'supports': 'Same original request'}]},
            {'threadId': 'background-fixture', 'title': 'Related passport preparation', 'projectId': None, 'hostId': 'local',
             'role': 'background', 'status': 'idle', 'relevance': 'Related preparation only',
             'evidence': [{'sourceReference': 'fixture turn 2', 'excerpt': 'We prepared the passport documents.', 'supports': 'Preparation; not appointment ownership'}]},
        ], 'uncertainties': ['The applicant is not established by the related chat.'],
    }
    # Reproduce the IKEA failure with context larger than default shell output.
    for index in range(4):
        receipt['chats'].append({'threadId': f'background-{index}', 'title': f'Background {index}', 'projectId': None, 'hostId': 'local', 'role': 'background', 'status': 'idle', 'relevance': 'Large fixture context', 'evidence': [{'sourceReference': f'fixture {index}/{part}', 'excerpt': str(index) * 1200, 'supports': 'Bounded original excerpt'} for part in range(3)]})
    context_file = directory / 'discovery.json'
    context_file.write_text(json.dumps(receipt))
    enriched = helper('--runner', 'context', '--runner-id', 'memory-smoke-runner', '--dispatch-id', delivery['dispatch']['id'], '--context-file', str(context_file))
    assert enriched['discovery']['required'] is False
    assert 'workerPrompt' not in enriched and len(json.dumps(enriched)) < 4000
    assert pathlib.Path(enriched['discovery']['contextFile']).exists()
    _, prepared = prepare(enriched)
    assert len(prepared['workerPrompt']) > 12000
    assert 'codex://threads/background-fixture' in prepared['workerPrompt'] and 'The applicant is not established' in prepared['workerPrompt']
    assert enriched['dispatch']['threadId'] == 'smoke-thread'
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT count(*) FROM threadLinks WHERE codexThreadId = 'background-fixture'").fetchone()[0] == 0
    # Exercise a real timed wake through the MCP plan/report tools and bundled runner.
    begin(enriched)
    helper('--runner', 'ack', '--runner-id', 'memory-smoke-runner', '--dispatch-id', delivery['dispatch']['id'], '--thread-id', 'smoke-thread')
    check_task = call('task_create', {'title': 'Check isolated fixture', 'nextAction': 'Read fixture', 'returnAt': '2030-01-01T12:00:00Z'})
    check_id, check_handle = check_task['id'], check_task['handle']
    call('link_thread', {'taskId': check_handle, 'threadId': 'check-smoke-thread'})
    assert call('get_check_plan', {'taskId': check_handle}) is None
    next_date = (datetime.now(timezone.utc) + timedelta(seconds=2)).isoformat()
    plan = call('plan_check', {'taskId': check_handle, 'threadId': 'check-smoke-thread', 'expectedRevision': '0', 'nextCheck': next_date, 'purpose': 'Inspect the isolated fixture', 'reason': 'Short integration-test wake', 'waitingOn': 'Fixture'})
    due = helper('--runner', 'wait', '--runner-id', 'memory-smoke-runner', '--seconds', '4')
    assert due['dispatch']['kind'] == 'check' and due['dispatch']['threadId'] == 'check-smoke-thread'
    _, prepared = prepare(due)
    assert 'scheduled dependency check' in prepared['workerPrompt'] and 'facienda_report_check' in prepared['workerPrompt']
    dispatch_id = due['dispatch']['id']
    begin(due)
    helper('--runner', 'ack', '--runner-id', 'memory-smoke-runner', '--dispatch-id', dispatch_id, '--thread-id', 'check-smoke-thread')
    report = {'taskId': check_handle, 'dispatchId': dispatch_id, 'expectedRevision': str(plan['revision']), 'outcome': 'unchanged', 'summary': 'Fixture unchanged', 'nextCheck': (datetime.now(timezone.utc) + timedelta(seconds=10)).isoformat(), 'reason': 'Wait for the fixture to change'}
    saved = call('report_check', report)
    assert saved['revision'] == plan['revision'] + 1 and saved['checks'] == 1
    assert datetime.fromisoformat(saved['nextCheck']) > datetime.now(timezone.utc) + timedelta(minutes=59)
    assert call('report_check', report)['revision'] == saved['revision']
    assert call('current_task', {'threadId': 'check-smoke-thread', 'taskId': check_handle})['state'] == 'waiting'
    call('current_task', {'threadId': 'check-smoke-thread', 'taskId': task_handle}, error=True)
    # Link blockers through the real MCP transport, then release precisely one held start.
    created = call('task_create', {'title': 'Blocked fixture', 'nextAction': 'Act after fixtures', 'returnAt': '2030-01-01T12:00:00Z'})
    dependent, dependent_handle = created['id'], created['handle']
    call('link_thread', {'taskId': dependent_handle, 'threadId': 'blocker-smoke-thread'})
    edges = call('set_blocker', {'taskId': dependent_handle, 'kind': 'task', 'prerequisiteId': check_id})
    condition = call('set_blocker', {'taskId': dependent_handle, 'kind': 'condition', 'title': 'Fixture ready', 'sourceReference': 'Local smoke fixture', 'criterion': 'Ready flag is true'})
    state = call('get_blockers', {'taskId': dependent_handle})
    assert len(state['blockers']) == 2 and state['readiness']['armed'] is False
    call('set_blocker', {'taskId': check_handle, 'kind': 'task', 'prerequisiteId': dependent}, error=True)
    # An agent never arms a start: the user is asked, and their answer in the app arms it.
    asked = call('set_readiness', {'taskId': dependent_handle, 'armed': 'true', 'userInstruction': 'Start when the fixtures are ready'})
    assert asked['readiness']['armed'] is False and asked['decision']['kind'] == 'permission'
    assert call('get_blockers', {'taskId': dependent_handle})['readiness']['armed'] is False
    with sqlite3.connect(database) as db:
        db.execute("UPDATE decisions SET state = 'answered', answer = 'Start when ready', answeredAt = ? WHERE id = ?",
                   (datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S.000'), asked['decision']['id']))
    due = helper('--runner', 'wait', '--runner-id', 'memory-smoke-runner', '--seconds', '1')
    assert due['dispatch']['kind'] == 'check' and due['dispatch']['taskId'] == dependent
    _, prepared = prepare(due)
    assert 'blockerReports' in prepared['workerPrompt'] and condition['id'] in prepared['workerPrompt']
    marker = due['dispatch']['id']
    begin(due)
    helper('--runner', 'ack', '--runner-id', 'memory-smoke-runner', '--dispatch-id', marker, '--thread-id', 'blocker-smoke-thread')
    report = {'taskId': dependent_handle, 'dispatchId': marker, 'expectedRevision': str(due['dispatch']['checkRevision']), 'outcome': 'changed', 'summary': 'Fixture is ready', 'blockerReports': [{'blockerId': condition['id'], 'expectedRevision': condition['revision'], 'status': 'met', 'evidence': 'Local fixture: ready=true'}]}
    call('report_check', dict(report, blockerReports=[]), error=True)
    call('report_check', report)
    assert helper('--runner', 'wait', '--runner-id', 'memory-smoke-runner', '--seconds', '1')['status'] == 'timeout'
    call('remove_blocker', {'taskId': dependent_handle, 'blockerId': edges[0]['id'], 'expectedRevision': str(edges[0]['revision']), 'userInstruction': 'Remove the fixture task prerequisite'})
    ready = helper('--runner', 'wait', '--runner-id', 'memory-smoke-runner', '--seconds', '1')
    assert ready['dispatch']['kind'] == 'ready' and ready['dispatch']['threadId'] == 'blocker-smoke-thread'
    call('set_readiness', {'taskId': dependent_handle, 'armed': 'false', 'userInstruction': 'Cancel this fixture run'})
    assert helper('--runner', 'wait', '--runner-id', 'memory-smoke-runner', '--seconds', '1')['status'] == 'timeout'
    # The native CLI reconstructs URLs from paths. A task's own folder sits in the data folder beside the
    # library's folder, and routes through the project without separate folder registration.
    for base, automatic in [(directory.parent, True), (directory / 'Work', False), (directory / 'Chosen project', False)]:
        routing_id = call('task_create', {'title': 'Find a prior spa hotel chat', 'nextAction': 'Search prior chats', 'returnAt': '2030-01-01T12:00:00Z'})['id']
        working = base / routing_id
        working.mkdir(parents=True)
        with sqlite3.connect(database) as db:
            db.execute('UPDATE tasks SET cwd = ? WHERE id = ?', (str(working), routing_id))
        start(routing_id)
        delivery = helper('--runner', 'wait', '--runner-id', 'memory-smoke-runner', '--seconds', '1')
        assert delivery['discovery']['workingFolderIsAutomatic'] is automatic
        project = directory / 'Related project' if automatic else working.parent
        project.mkdir(exist_ok=True)
        receipt = {'contextKey': delivery['discovery']['contextKey'], 'searchStatus': 'complete',
                   'searchSummary': 'Isolated inventory has no prior owner; verified fixture project.',
                   'route': 'new', 'project': {'id': 'routing-fixture', 'path': str(project), 'reason': 'Verified fixture project'},
                   'chats': [], 'uncertainties': []}
        context_file.write_text(json.dumps(receipt))
        enriched = helper('--runner', 'context', '--runner-id', 'memory-smoke-runner', '--dispatch-id', delivery['dispatch']['id'], '--context-file', str(context_file))
        prepared = begin(enriched)
        expected_folder = str(project if automatic else working)
        assert prepared['workingFolder'] == expected_folder
        assert f'Working folder: {expected_folder}.' in prepared['workerPrompt']
        assert prepared['targetProject']['id'] == 'routing-fixture'
        helper('--runner', 'ack', '--runner-id', 'memory-smoke-runner', '--dispatch-id', delivery['dispatch']['id'], '--thread-id', 'routing-' + routing_id)
    print(json.dumps({'sharedWorkspace': args.workspace, 'mcpTools': len(tools), 'stdioProtocol': 'passed', 'agentCompletionRejected': True, 'workspaceMemory': 'passed', 'contextualDispatch': 'passed', 'workingFolderRouting': 'passed', 'compactHandoff': 'passed', 'queuedDispatchMilliseconds': queue_ms, 'queueMemoryRequests': len(memory_requests), 'timedChecks': 'passed', 'dependencyGate': 'passed', 'hookMilliseconds': timings, 'lockedDatabaseHookMilliseconds': locked_ms, 'database': str(database)}, indent=2))
finally:
    process.stdin.close()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=3)
