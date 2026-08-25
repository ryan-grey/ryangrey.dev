#!/usr/bin/env python3
"""
Fails the deploy if infra/corpus.json no longer matches its sources.

The chatbot answers from a corpus generated out of index.html and the CV.
If the site changes and the corpus isn't rebuilt, the bot keeps answering
from stale content -- a wrong answer to a recruiter, which is worse than a
broken build. Same contract as check-stack-drift.py: green means consistent,
not merely uploaded.

Checked here:
  - index.html sha256 matches what the corpus recorded  (hard fail)
  - every chunk vector has the declared dimension count  (hard fail)
  - the embedding model matches the one the Lambda uses (hard fail)

Not checkable in CI: the CV source lives outside the repo, so its text is
frozen into corpus.json at build time. build-corpus.py warns locally when it
changes. Stated rather than silently skipped.

Usage: python3 infra/check-corpus-drift.py
"""
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXPECTED_MODEL = "amazon.titan-embed-text-v2:0"
EXPECTED_DIMS = 1024


def main():
    corpus_path = ROOT / "infra" / "corpus.json"
    if not corpus_path.exists():
        print("FAIL: infra/corpus.json missing -- run infra/build-corpus.py")
        return 1

    doc = json.loads(corpus_path.read_text())
    failed = False

    print(f"corpus: {len(doc['chunks'])} chunks, {doc['dims']} dims, model {doc['model']}")

    if doc.get("model") != EXPECTED_MODEL:
        failed = True
        print(f"\nFAIL: corpus embedded with {doc.get('model')}, "
              f"but the Lambda queries with {EXPECTED_MODEL}.")
        print("Vectors from different embedding models are not comparable.")

    if doc.get("dims") != EXPECTED_DIMS:
        failed = True
        print(f"\nFAIL: corpus declares {doc.get('dims')} dims, expected {EXPECTED_DIMS}")

    bad = [i for i, c in enumerate(doc["chunks"]) if len(c.get("vector", [])) != doc["dims"]]
    if bad:
        failed = True
        print(f"\nFAIL: {len(bad)} chunk(s) have the wrong vector length: {bad[:5]}")

    live = hashlib.sha256((ROOT / "index.html").read_bytes()).hexdigest()
    recorded = (doc.get("sources") or {}).get("index.html")
    if live != recorded:
        failed = True
        print("\nFAIL: index.html has changed since the corpus was built.")
        print(f"  corpus recorded: {recorded}")
        print(f"  index.html now:  {live}")
        print("  Rebuild with: python3 infra/build-corpus.py")

    if not (doc.get("sources") or {}).get("cv"):
        print("\nadvisory: no CV hash recorded -- corpus was built without the CV source")

    if failed:
        print("\nThe chatbot would answer from stale content. Not shipping it.")
        return 1

    print("OK: corpus matches index.html and its declared model/dimensions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
