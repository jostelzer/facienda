import sys, json, time

def send(value):
    # Fragmented writes exercise newline framing independently of read boundaries.
    data = json.dumps(value) + '\n'
    for chunk in (data[:9], data[9:]):
        sys.stdout.write(chunk)
        sys.stdout.flush()

signed_in = False
projects = []
thread_responses = {}
thread_reads = []
history_requests = []
summary_failures = set()
repeated_cursors = set()
list_pages = {}
archived = []
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if method == 'initialize':
        send({'id': request['id'], 'result': {'userAgent': 'fixture'}})
    elif method == 'account/read':
        send({'id': request['id'], 'result': {'account': {'type': 'chatgpt'} if signed_in else None, 'requiresOpenaiAuth': True}})
    elif method == 'account/login/start':
        assert request['params'] == {'type': 'chatgpt', 'useHostedLoginSuccessPage': True, 'appBrand': 'codex'}
        send({'id': request['id'], 'result': {'type': 'chatgpt', 'loginId': 'fixture-login', 'authUrl': 'https://auth.openai.com/fixture-only'}})
    elif method == 'account/login/cancel':
        assert request['params']['loginId'] == 'fixture-login'
        send({'id': request['id'], 'result': {}})
        send({'method': 'account/login/completed', 'params': {'loginId': 'fixture-login', 'success': False, 'error': 'Cancelled'}})
    elif method == 'fixture/completeLogin':
        signed_in = True
        send({'id': request['id'], 'result': {}})
        send({'method': 'account/login/completed', 'params': {'loginId': 'fixture-login', 'success': True}})
    elif method == 'thread/list' and list_pages:
        page = list_pages[request['params'].get('cursor') or '']
        send({'id': request['id'], 'result': page})
    elif method == 'fixture/setThreadList':
        list_pages = request['params']['pages']
        send({'id': request['id'], 'result': {}})
    elif method == 'thread/list':
        send({'method':'thread/status/changed','params':{'threadId':'fixture','status':{'type':'active','activeFlags':[]}}})
        send({'id':request['id'],'result':{'data':[{'id':'fixture','name':'Fixture thread','preview':'Read only','cwd':'/tmp','updatedAt':1791068400,'status':{'type':'notLoaded'}}],'nextCursor':'page2'}})
    elif method == 'fixture/setThread':
        params = request['params']
        thread_id = params['threadId']
        thread_responses[thread_id] = params['response']
        if params.get('failSummary'):
            summary_failures.add(thread_id)
        if params.get('repeatCursor'):
            repeated_cursors.add(thread_id)
        send({'id': request['id'], 'result': {}})
    elif method == 'fixture/threadReads':
        send({'id': request['id'], 'result': {'ids': thread_reads, 'requests': history_requests}})
    elif method == 'fixture/oversizedResponse':
        send({'id': request['id'], 'result': {'text': 'x' * (2 * 1024 * 1024)}})
    elif method == 'fixture/largeResponse':
        send({'id': request['id'], 'result': {'text': 'x' * (17 * 1024 * 1024)}})
    elif method == 'thread/queue/list':
        send({'id': request['id'], 'result': {'data': [], 'nextCursor': None}})
    elif method == 'thread/turns/list':
        params = request['params']
        history_requests.append({'method': method, **params})
        thread_id = params['threadId']
        assert params['itemsView'] == 'summary'
        if thread_id in thread_responses and thread_id not in summary_failures:
            turns = thread_responses[thread_id]['thread']['turns']
            if params.get('sortDirection') != 'asc':
                turns = list(reversed(turns))
            start = int(params.get('cursor') or 0)
            page = []
            for turn in turns[start:start + params['limit']]:
                items = [item for item in turn['items'] if item['type'] == 'userMessage' or
                         (item['type'] == 'agentMessage' and item.get('phase') != 'commentary')]
                page.append({**turn, 'items': items})
            end = start + len(page)
            next_cursor = str(end) if end < len(turns) else None
            if thread_id in repeated_cursors:
                next_cursor = params.get('cursor') or '0'
            send({'id': request['id'], 'result': {'data': page, 'nextCursor': next_cursor}})
        else:
            send({'id': request['id'], 'error': {'code': -32000, 'message': 'Fixture chat unavailable'}})
    elif method == 'thread/read' and request['params']['includeTurns'] is False:
        # A details-only read, as setup uses to see whether the runner's chat still exists.
        thread_id = request['params']['threadId']
        thread_reads.append(thread_id)
        history_requests.append({'method': method, **request['params']})
        if thread_id in thread_responses:
            send({'id': request['id'], 'result': {'thread': {**thread_responses[thread_id]['thread'], 'turns': []}}})
        else:
            send({'id': request['id'], 'error': {'code': -32000, 'message': 'Fixture chat unavailable'}})
    elif method == 'thread/read':
        assert request['params']['includeTurns'] is True
        history_requests.append({'method': method, **request['params']})
        send({'id': request['id'], 'error': {'code': -32000, 'message': 'Whole history reads are not allowed'}})
    elif method == 'project/list':
        send({'id': request['id'], 'result': {'data': projects, 'nextCursor': None}})
    elif method == 'fixture/registerProject' or method == 'project/create':
        params = request['params']
        assert not params['roots'][0]['path'].endswith('/facienda-WORKSPACE')
        if method == 'project/create' and not params.get('idempotencyKey'):
            send({'id': request['id'], 'error': {'code': -32600, 'message': 'Invalid request: missing field `idempotencyKey`'}})
            continue
        project = {'id': 'project-' + str(len(projects)), 'name': params['name'], 'roots': params['roots']}
        projects.append(project)
        send({'id': request['id'], 'result': {'project': project}})
    elif method == 'project/update':
        params = request['params']
        project = next(p for p in projects if p['id'] == params['projectId'])
        assert set(params) == {'projectId', 'name'}
        project['name'] = params['name']
        send({'id': request['id'], 'result': {'project': project}})
    elif method == 'thread/archive':
        archived.append(request['params']['threadId'])
        send({'id': request['id'], 'result': {}})
    elif method == 'fixture/archived':
        send({'id': request['id'], 'result': {'threads': archived}})
    elif method == 'fail':
        send({'id':request['id'],'error':{'code':-32000,'message':'Deliberate fixture failure'}})
    elif method == 'thread/start':
        params = request['params']
        assert params['approvalPolicy'] == 'on-request'
        assert params['approvalsReviewer'] == 'user'
        assert params['config']['mcp_servers']['facienda']['command']
        assert params['config']['mcp_servers']['facienda']['required'] is True
        send({'id':request['id'],'result':{'thread':{'id':'owned','name':'Owned fixture','preview':'','cwd':'/tmp','updatedAt':1791068400,'status':{'type':'idle'}}}})
    elif method == 'turn/start':
        assert request['params']['input'][0]['type'] == 'text'
        send({'id':request['id'],'result':{'turn':{'id':'turn-fixture'}}})
        send({'method':'turn/started','params':{'threadId':'owned','turn':{'id':'turn-fixture'}}})
        send({'id':77,'method':'item/commandExecution/requestApproval','params':{'threadId':'owned','turnId':'turn-fixture','itemId':'command','command':'echo fixture'}})
    elif request.get('id') == 77 and 'result' in request:
        assert request['result']['decision'] == 'decline'
        send({'method':'turn/completed','params':{'threadId':'owned','turn':{'id':'turn-fixture','status':'completed'}}})
    elif method == 'hang':
        pass
    elif method == 'exit':
        sys.exit(0)
    elif method:
        send({'id':request.get('id'),'result':{}})
