"""AIF Study Engine — quiz generation, progress tracking and a spaced-repetition miss log.

Auth is enforced twice on purpose. The HTTP API carries a Cognito JWT authorizer, so an
unauthenticated request never reaches this code and can never spend Bedrock money. This
handler then re-checks the claims it actually cares about, because "the gateway probably
did it" is not something worth betting an API bill on.

The hard product rule is that a quiz may never ask about a lesson Ryan has not finished.
That is enforced in two places for the same reason: the model is only ever SHOWN in-scope
lesson titles, and every question it returns is then checked against the allowed set and
dropped if it strays. A prompt instruction is not a boundary; the filter is.
"""

import json
import os
import re
import time
from datetime import datetime, timedelta, timezone

import boto3
from botocore.config import Config

REGION = os.environ.get("AWS_REGION", "us-east-1")
TABLE = os.environ.get("QUIZ_TABLE", "ryangrey-quiz")
MODEL = os.environ.get("CHAT_MODEL", "us.amazon.nova-lite-v1:0")
ALLOWED_SUB = os.environ.get("ALLOWED_SUB", "")
MAX_QUESTIONS = 12

# Spaced repetition ladder, in days, indexed by how many times the item has been answered
# correctly in a row. A third correct answer retires it, so the ladder only needs two rungs.
LADDER = [1, 3, 7]

_cfg = Config(retries={"max_attempts": 2, "mode": "standard"}, read_timeout=45)
brt = boto3.client("bedrock-runtime", region_name=REGION, config=_cfg)
ddb = boto3.client("dynamodb", region_name=REGION, config=_cfg)

with open(os.path.join(os.path.dirname(__file__), "aif-c01-course.json")) as fh:
    COURSE = json.load(fh)

LESSONS = [dict(l, moduleId=m["id"], moduleName=m["name"], domain=m["primaryDomain"])
           for m in COURSE["modules"] for l in m["lessons"]]
LESSON_BY_ID = {l["id"]: l for l in LESSONS}
MAX_ORDER = max(l["order"] for l in LESSONS)
DOMAINS = {d["id"]: d for d in COURSE["domains"]}


# ---------------------------------------------------------------- helpers

def _resp(code, body):
    return {"statusCode": code,
            "headers": {"content-type": "application/json",
                        "cache-control": "no-store"},
            "body": json.dumps(body)}


def _now():
    return datetime.now(timezone.utc)


def _iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _claims(event):
    """Claims the JWT authorizer already validated. Absent means misconfiguration, so
    fail closed rather than falling back to unauthenticated."""
    try:
        return event["requestContext"]["authorizer"]["jwt"]["claims"]
    except (KeyError, TypeError):
        return None


def _pk(sub):
    return {"S": f"USER#{sub}"}


def _s(v):
    return {"S": str(v)}


def _n(v):
    return {"N": str(v)}


def _plain(item):
    """Flatten a DynamoDB item into plain Python."""
    out = {}
    for k, v in (item or {}).items():
        if "S" in v:
            out[k] = v["S"]
        elif "N" in v:
            out[k] = int(v["N"]) if "." not in v["N"] else float(v["N"])
        elif "BOOL" in v:
            out[k] = v["BOOL"]
    return out


# ---------------------------------------------------------------- storage

def get_progress(sub):
    res = ddb.get_item(TableName=TABLE, Key={"pk": _pk(sub), "sk": _s("PROGRESS")})
    item = _plain(res.get("Item"))
    order = int(item.get("completedThroughOrder", 0))
    return max(0, min(order, MAX_ORDER))


def put_progress(sub, order):
    order = max(0, min(int(order), MAX_ORDER))
    ddb.put_item(TableName=TABLE, Item={
        "pk": _pk(sub), "sk": _s("PROGRESS"),
        "completedThroughOrder": _n(order), "updatedAt": _s(_iso(_now()))})
    return order


def query_misses(sub):
    """Query, never Scan — the execution role has no Scan and the item count is tens."""
    out, start = [], None
    while True:
        kw = dict(TableName=TABLE,
                  KeyConditionExpression="pk = :p AND begins_with(sk, :m)",
                  ExpressionAttributeValues={":p": _pk(sub), ":m": _s("MISS#")})
        if start:
            kw["ExclusiveStartKey"] = start
        res = ddb.query(**kw)
        out.extend(_plain(i) for i in res.get("Items", []))
        start = res.get("LastEvaluatedKey")
        if not start:
            break
    return out


def upsert_miss(sub, concept_id, fields):
    names, values, sets = {}, {}, []
    for i, (k, v) in enumerate(fields.items()):
        names[f"#k{i}"] = k
        values[f":v{i}"] = _n(v) if isinstance(v, int) else _s(v)
        sets.append(f"#k{i} = :v{i}")
    ddb.update_item(
        TableName=TABLE, Key={"pk": _pk(sub), "sk": _s(f"MISS#{concept_id}")},
        UpdateExpression="SET " + ", ".join(sets),
        ExpressionAttributeNames=names, ExpressionAttributeValues=values)


def put_session(sub, payload):
    ddb.put_item(TableName=TABLE, Item={
        "pk": _pk(sub), "sk": _s(f"SESSION#{_iso(_now())}"),
        "correct": _n(payload.get("correct", 0)),
        "total": _n(payload.get("total", 0)),
        "byDomain": _s(json.dumps(payload.get("byDomain", {}))),
        "throughOrder": _n(payload.get("throughOrder", 0))})


def query_sessions(sub, limit=30):
    res = ddb.query(TableName=TABLE,
                    KeyConditionExpression="pk = :p AND begins_with(sk, :s)",
                    ExpressionAttributeValues={":p": _pk(sub), ":s": _s("SESSION#")},
                    ScanIndexForward=False, Limit=limit)
    out = []
    for raw in res.get("Items", []):
        item = _plain(raw)
        try:
            item["byDomain"] = json.loads(item.get("byDomain") or "{}")
        except ValueError:
            item["byDomain"] = {}
        item["date"] = item.get("sk", "")[len("SESSION#"):]
        out.append(item)
    return out


# ---------------------------------------------------------------- generation

SYSTEM = """You write multiple-choice exam questions for the AWS Certified AI Practitioner
(AIF-C01) exam. You are quizzing one learner who is partway through the course.

Rules you follow without exception:
- Write questions ONLY about the lessons listed as IN SCOPE. Never write a question that
  requires knowledge from a lesson that is not listed, even if it is obviously related.
- Every question must carry the lessonId of the in-scope lesson it tests.
- Exactly one choice is correct. Make the distractors plausible and commonly confused.
- Prefer scenario-style wording, the format the real exam uses.
- The explanation states why the right answer is right AND why the tempting wrong one is
  wrong, in two sentences or fewer.
- Reply with JSON only. No markdown fence, no commentary."""


def _scope(order):
    return [l for l in LESSONS if l["order"] <= order]


def _prompt(order, count, due):
    in_scope = _scope(order)
    lines = [f'- {l["id"]} ({DOMAINS[l["domain"]]["name"]}): {l["moduleName"]} — {l["name"]}'
             for l in in_scope]
    parts = ["IN SCOPE — the only lessons you may test:", "\n".join(lines)]
    if due:
        warm = "\n".join(f'- conceptId {m["conceptId"]} (lesson {m.get("lessonId","?")}): '
                         f'{m.get("concept","")} — the learner previously got this wrong: '
                         f'{m.get("rule","")}' for m in due)
        parts.append(
            "WARM-UP — write exactly one question for EACH concept below. These are things "
            "the learner has already missed and is re-drilling. Test the same distinction "
            "with a DIFFERENT scenario than before. Mark each with its conceptId.\n" + warm)
    parts.append(
        f"Write {count} NEW questions drawn from the in-scope lessons, weighted toward the "
        f"later lessons the learner has just covered.")
    parts.append(
        'Reply with exactly this JSON shape:\n'
        '{"warmups":[{"conceptId":"...","lessonId":"...","domain":"D1",'
        '"question":"...","choices":["...","...","...","..."],"answerIndex":0,'
        '"explanation":"..."}],'
        '"questions":[{"lessonId":"...","domain":"D1","question":"...",'
        '"choices":["...","...","...","..."],"answerIndex":0,"explanation":"..."}]}')
    return "\n\n".join(parts)


def _extract_json(text):
    text = text.strip()
    text = re.sub(r"^```(?:json)?|```$", "", text, flags=re.M).strip()
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("no JSON object in model output")
    return json.loads(text[start:end + 1])


def _valid(q):
    return (isinstance(q.get("choices"), list) and len(q["choices"]) >= 2
            and isinstance(q.get("answerIndex"), int)
            and 0 <= q["answerIndex"] < len(q["choices"])
            and q.get("question") and q.get("lessonId"))


def generate(order, count, due):
    """One Bedrock call for warm-ups and new questions together. Retries once on unparseable
    output, then fails closed — a quiz rendered from half-parsed JSON is worse than none."""
    prompt, last = _prompt(order, count, due), None
    for attempt in (1, 2):
        res = brt.converse(
            modelId=MODEL,
            system=[{"text": SYSTEM}],
            messages=[{"role": "user", "content": [{"text": prompt}]}],
            inferenceConfig={"maxTokens": 4000, "temperature": 0.7 if attempt == 1 else 0.2})
        text = res["output"]["message"]["content"][0]["text"]
        usage = res.get("usage", {})
        try:
            data = _extract_json(text)
            return data, usage
        except ValueError as exc:
            last = exc
            print(json.dumps({"event": "parse_retry", "attempt": attempt, "error": str(exc)}))
    raise RuntimeError(f"model output unparseable after 2 attempts: {last}")


def enforce_scope(items, order):
    """The second line of defence. Anything outside the window is dropped and LOGGED, so a
    scope leak shows up in CloudWatch instead of silently reaching the learner."""
    allowed = {l["id"] for l in _scope(order)}
    kept, dropped = [], []
    for q in items:
        if not _valid(q):
            dropped.append({"lessonId": q.get("lessonId"), "why": "malformed"})
            continue
        if q["lessonId"] not in allowed:
            dropped.append({"lessonId": q.get("lessonId"), "why": "out_of_scope"})
            continue
        kept.append(q)
    if dropped:
        print(json.dumps({"event": "scope_filter", "throughOrder": order,
                          "kept": len(kept), "dropped": dropped}))
    return kept, dropped


# ---------------------------------------------------------------- routes

def route_state(sub):
    order = get_progress(sub)
    misses = query_misses(sub)
    today = _iso(_now())
    for m in misses:
        m["due"] = m.get("status") == "OPEN" and m.get("dueAt", "") <= today
    return _resp(200, {
        "throughOrder": order,
        "maxOrder": MAX_ORDER,
        "course": COURSE,
        "misses": sorted(misses, key=lambda m: m.get("dueAt", "")),
        "sessions": query_sessions(sub),
    })


def route_progress(sub, body):
    order = put_progress(sub, body.get("throughOrder", 0))
    lesson = next((l for l in LESSONS if l["order"] == order), None)
    return _resp(200, {"throughOrder": order,
                       "lesson": lesson["name"] if lesson else "nothing completed yet"})


def route_generate(sub, body):
    order = get_progress(sub)
    if order <= 0:
        return _resp(400, {"error": "Set your progress first — no lessons are marked complete, "
                                    "so there is nothing in scope to quiz on."})
    count = max(1, min(int(body.get("count", 8)), MAX_QUESTIONS))
    today = _iso(_now())
    due = [m for m in query_misses(sub)
           if m.get("status") == "OPEN" and m.get("dueAt", "") <= today][:5]
    started = time.time()
    data, usage = generate(order, count, due)
    warmups, w_dropped = enforce_scope(data.get("warmups", []), order)
    questions, q_dropped = enforce_scope(data.get("questions", []), order)
    if not warmups and not questions:
        return _resp(502, {"error": "The model returned no in-scope questions. Nothing was "
                                    "shown rather than risk asking about unfinished lessons."})
    print(json.dumps({"event": "generate", "throughOrder": order,
                      "inScopeLessons": len(_scope(order)), "due": len(due),
                      "warmups": len(warmups), "questions": len(questions),
                      "dropped": len(w_dropped) + len(q_dropped),
                      "in": usage.get("inputTokens"), "out": usage.get("outputTokens"),
                      "ms": int((time.time() - started) * 1000)}))
    return _resp(200, {"throughOrder": order, "warmups": warmups, "questions": questions,
                       "droppedOutOfScope": len(w_dropped) + len(q_dropped)})


def route_answer(sub, body):
    """Record one answered question. A miss opens or resets a log entry; a correct answer on
    an open entry advances its streak, and two in a row retire it."""
    correct = bool(body.get("correct"))
    concept_id = (body.get("conceptId") or body.get("lessonId") or "unknown")[:120]
    lesson_id = body.get("lessonId", "")
    lesson = LESSON_BY_ID.get(lesson_id, {})
    now = _now()

    existing = {m["sk"][len("MISS#"):]: m for m in query_misses(sub)}
    prior = existing.get(concept_id)

    if correct:
        if not prior or prior.get("status") != "OPEN":
            return _resp(200, {"recorded": True, "miss": None})
        streak = int(prior.get("correctStreak", 0)) + 1
        if streak >= 2:
            upsert_miss(sub, concept_id, {"status": "RETIRED", "correctStreak": streak,
                                          "retiredAt": _iso(now)})
            return _resp(200, {"recorded": True, "miss": {"conceptId": concept_id,
                                                          "status": "RETIRED"}})
        due = now + timedelta(days=LADDER[min(streak, len(LADDER) - 1)])
        upsert_miss(sub, concept_id, {"correctStreak": streak, "dueAt": _iso(due)})
        return _resp(200, {"recorded": True, "miss": {"conceptId": concept_id,
                                                      "status": "OPEN", "correctStreak": streak}})

    due = now + timedelta(days=LADDER[0])
    upsert_miss(sub, concept_id, {
        "status": "OPEN", "correctStreak": 0, "dueAt": _iso(due),
        "concept": (body.get("concept") or "")[:400],
        "rule": (body.get("explanation") or "")[:600],
        "wrongChoice": (body.get("chosen") or "")[:300],
        "lessonId": lesson_id,
        "moduleId": lesson.get("moduleId", ""),
        "domain": body.get("domain") or lesson.get("domain", ""),
        "lastMissedAt": _iso(now)})
    return _resp(200, {"recorded": True, "miss": {"conceptId": concept_id, "status": "OPEN",
                                                  "correctStreak": 0}})


def route_session(sub, body):
    body["throughOrder"] = get_progress(sub)
    put_session(sub, body)
    return _resp(200, {"recorded": True})


ROUTES = {
    ("GET", "/api/quiz/state"): lambda sub, body: route_state(sub),
    ("POST", "/api/quiz/progress"): route_progress,
    ("POST", "/api/quiz/generate"): route_generate,
    ("POST", "/api/quiz/answer"): route_answer,
    ("POST", "/api/quiz/session"): route_session,
}


def handler(event, context):
    claims = _claims(event)
    if not claims:
        return _resp(401, {"error": "Not signed in."})
    if claims.get("token_use") not in ("id", "access"):
        return _resp(401, {"error": "Wrong token type."})
    sub = claims.get("sub", "")
    if not sub or (ALLOWED_SUB and sub != ALLOWED_SUB):
        return _resp(403, {"error": "This study engine has one user."})

    http = event.get("requestContext", {}).get("http", {})
    key = (http.get("method", ""), event.get("rawPath", ""))
    fn = ROUTES.get(key)
    if not fn:
        return _resp(404, {"error": f"No route for {key[0]} {key[1]}"})

    try:
        body = json.loads(event.get("body") or "{}")
    except ValueError:
        return _resp(400, {"error": "Body must be JSON."})

    try:
        return fn(sub, body)
    except Exception as exc:                                   # noqa: BLE001
        print(json.dumps({"event": "error", "route": key[1], "error": repr(exc)}))
        return _resp(500, {"error": "Something failed server-side. Nothing was recorded."})
