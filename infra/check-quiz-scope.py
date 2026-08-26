#!/usr/bin/env python3
"""Scope-compliance self-test for the AIF Study Engine.

The hard product rule is that a quiz may never test a lesson Ryan has not completed. This
asserts that rule against the REAL handler code at every possible progress marker, with no
AWS involved: boto3 is stubbed before import so the module loads without credentials or the
SDK installed. Runs in CI ahead of any deploy.

Three things are checked, and the middle one matters most:
  1. the in-scope set is exactly the lessons at or below the marker
  2. the PROMPT never mentions an out-of-scope lesson -- the model cannot leak what it was
     never shown, so this is the real containment
  3. the post-filter drops out-of-scope and malformed questions that a model returns anyway
"""

import json
import pathlib
import sys
import types

ROOT = pathlib.Path(__file__).resolve().parent


def _stub_boto3():
    """Import the handler without the AWS SDK. It builds clients at module scope, which is
    right for Lambda (warm reuse) and inconvenient here; stubbing beats restructuring
    production code to suit its test."""
    boto3 = types.ModuleType("boto3")
    boto3.client = lambda *a, **k: types.SimpleNamespace()
    sys.modules["boto3"] = boto3
    botocore = types.ModuleType("botocore")
    config = types.ModuleType("botocore.config")
    config.Config = lambda *a, **k: None
    botocore.config = config
    sys.modules["botocore"] = botocore
    sys.modules["botocore.config"] = config


def load_handler():
    _stub_boto3()
    sys.path.insert(0, str(ROOT / "quiz"))
    # The handler reads the course file from its own directory; keep the deployed layout.
    target = ROOT / "quiz" / "aif-c01-course.json"
    if not target.exists():
        target.write_text((ROOT / "aif-c01-course.json").read_text())
    import handler
    return handler


def main():
    h = load_handler()
    failures = []
    lessons = h.LESSONS
    max_order = h.MAX_ORDER
    print(f"course: {len(lessons)} lessons, max order {max_order}")

    # 1. the in-scope set is exactly what the marker says
    for order in range(0, max_order + 1):
        scope = h._scope(order)
        expected = [l for l in lessons if l["order"] <= order]
        if [l["id"] for l in scope] != [l["id"] for l in expected]:
            failures.append(f"scope set wrong at marker {order}")
        beyond = [l["id"] for l in scope if l["order"] > order]
        if beyond:
            failures.append(f"marker {order}: scope contained future lessons {beyond}")

    # 2. the prompt never names a lesson beyond the marker
    for order in range(1, max_order + 1):
        prompt = h._prompt(order, 8, [])
        leaked = [l["id"] for l in lessons if l["order"] > order and l["id"] in prompt]
        if leaked:
            failures.append(f"marker {order}: PROMPT LEAKED future lesson ids {leaked[:5]}")

    # 2b. the warm-up path: a prompt built WITH due misses. This was missing, and the
    #     warm-up branch shipped broken because every test built a prompt with due=[].
    due_rows = [
        {"sk": "MISS#clarify-vs-monitor", "conceptId": "clarify-vs-monitor",
         "concept": "Clarify vs Model Monitor", "rule": "Clarify explains; Monitor watches.",
         "lessonId": "M3-01", "status": "OPEN"},
        {"sk": "MISS#no-concept-id"},           # a row missing everything optional
    ]
    try:
        warm_prompt = h._prompt(6, 8, due_rows)
        if "clarify-vs-monitor" not in warm_prompt:
            failures.append("warm-up prompt did not include the due conceptId")
        leaked = [l["id"] for l in lessons if l["order"] > 6 and l["id"] in warm_prompt]
        if leaked:
            failures.append(f"warm-up prompt leaked future lessons {leaked[:5]}")
    except Exception as exc:                                   # noqa: BLE001
        failures.append(f"building a prompt with due misses raised {exc!r}")

    # 3. the post-filter catches what a model returns anyway
    order = 4
    future = next(l for l in lessons if l["order"] == max_order)
    inscope = next(l for l in lessons if l["order"] == order)
    good = {"lessonId": inscope["id"], "question": "q", "choices": ["a", "b"],
            "answerIndex": 0, "explanation": "e"}
    cases = [
        (dict(good), True, "in-scope question kept"),
        (dict(good, lessonId=future["id"]), False, "out-of-scope question dropped"),
        (dict(good, lessonId="NOPE-99"), False, "unknown lesson dropped"),
        (dict(good, answerIndex=9), False, "answerIndex out of range dropped"),
        (dict(good, choices=[]), False, "empty choices dropped"),
        ({k: v for k, v in good.items() if k != "lessonId"}, False, "missing lessonId dropped"),
    ]
    for item, should_keep, label in cases:
        kept, dropped = h.enforce_scope([item], order)
        if bool(kept) != should_keep:
            failures.append(f"filter: {label} -- got kept={len(kept)} dropped={len(dropped)}")

    # 4. JSON extraction survives the shapes models actually emit
    payload = '{"warmups":[],"questions":[]}'
    for raw, label in [(payload, "bare"),
                       (f"```json\n{payload}\n```", "fenced"),
                       (f"Here you go:\n{payload}\nHope that helps.", "chatty")]:
        try:
            h._extract_json(raw)
        except ValueError as exc:
            failures.append(f"extract_json failed on {label} output: {exc}")

    print(f"checked markers 0..{max_order}, {len(cases)} filter cases, 3 output shapes")
    if failures:
        print("\nFAIL:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("OK: no quiz can reach a lesson beyond the progress marker")
    return 0


if __name__ == "__main__":
    sys.exit(main())
