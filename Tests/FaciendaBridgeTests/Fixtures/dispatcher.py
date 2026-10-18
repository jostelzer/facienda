import json
import sys


def send(value):
    print(json.dumps(value), flush=True)


settings = {}
requests = []
status = "notLoaded"
queued = []
turns = []


def consume():
    for entry in queued:
        turns.append({"id": entry["id"], "status": settings.get("turnStatus", "completed"),
                      "items": [{"type": "userMessage", "content": entry["input"]}]})
    queued.clear()


for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    params = request.get("params", {})
    result = {}
    if method == "initialized":
        continue
    if method == "fixture/configure":
        settings.update(params)
        status = params.get("status", status)
    elif method == "fixture/requests":
        result = {"methods": requests}
    elif method == "fixture/consume":
        consume()
    elif method == "fixture/remove":
        queued.clear()
    elif method == "fixture/setTurns":
        turns[:] = params["turns"]
    else:
        # A whole history can run to hundreds of megabytes, so these reads are counted apart.
        whole = (method == "thread/read" and params.get("includeTurns")) or (method == "thread/resume" and not params.get("excludeTurns"))
        requests.append(method)
        if whole:
            requests.append("whole history")
        if method in ("thread/resume", "thread/read"):
            result = {"thread": {"id": params["threadId"], "name": "Fixture", "status": {"type": status}, "turns": turns if whole else []}}
            if method == "thread/read" and "statusAfterRead" in settings:
                status = settings["statusAfterRead"]
        elif method == "thread/turns/list":
            assert params.get("sortDirection") == "desc"
            newest = list(reversed(turns))
            start = int(params.get("cursor") or 0)
            page = newest[start:start + params.get("limit", 25)]
            end = start + len(page)
            result = {"data": page, "nextCursor": str(end) if end < len(newest) else None}
        elif method == "thread/queue/list":
            result = {"data": queued, "nextCursor": None}
        elif method == "thread/queue/add":
            if settings.get("refuseAdd"):
                send({"id": request["id"], "error": {"code": -32000, "message": "Fixture refused queue add"}})
                continue
            entry = {"id": "queue-" + str(len(requests)), "clientUserMessageId": params["clientUserMessageId"], "input": params["input"]}
            queued.append(entry)
            if settings.get("consumeBeforeResponse"):
                consume()
            result = {} if settings.get("omitReceipt") else {"queuedSubmission": entry}
        elif method == "thread/unsubscribe":
            if settings.get("failRelease"):
                settings["failRelease"] = False
                send({"id": request["id"], "error": {"code": -32000, "message": "Fixture release failed"}})
                continue
            result = {"status": "unsubscribed"}
    send({"id": request["id"], "result": result})
