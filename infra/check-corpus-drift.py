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
  - corpus.json matches the corpus actually deployed to the Lambda, via the
    stamp deploy-chatbot.sh writes                      (hard fail)

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

    recorded_cv = (doc.get("sources") or {}).get("cv")
    if not recorded_cv:
        print("\nadvisory: no CV hash recorded -- corpus was built without the CV source")
    else:
        # The CV source lives outside the repo, so CI genuinely cannot check it and this stays
        # advisory there. But when the file IS present -- i.e. locally, where the CV is edited --
        # a mismatch is checkable and therefore a hard fail. Otherwise editing the resume leaves
        # the chatbot answering from an older one while every guard still reports OK, which is
        # exactly what happened on 2026-08-26.
        cv_path = Path.home() / "Documents/Resumes/Ryan_Grey_Resume_2026.source.html"
        if cv_path.exists():
            live_cv = hashlib.sha256(cv_path.read_bytes()).hexdigest()
            if live_cv != recorded_cv:
                print("\nFAIL: the CV source has changed since the corpus was built.")
                print(f"  corpus recorded: {recorded_cv}")
                print(f"  CV source now:   {live_cv}")
                print("\nRebuild with: python3 infra/build-corpus.py")
                print("Then redeploy:  infra/deploy-chatbot.sh")
                return 1
        else:
            print("advisory: CV source not present here -- cannot verify it (expected in CI)")

    # Has this corpus actually been deployed to the Lambda?
    #
    # Everything above proves corpus.json is consistent with its SOURCES. None
    # of it proves the bot is running that corpus. The corpus ships inside the
    # Lambda zip, and the site workflow's `aws s3 sync` excludes infra/*, so a
    # rebuilt corpus.json can be committed and deployed to the site while the
    # chatbot keeps serving the previous one -- every guard green, bot stale.
    # That happened on 2026-09-03 when the CV was restyled.
    #
    # deploy-chatbot.sh writes infra/corpus.deployed.sha256 after the function
    # update succeeds. Comparing against it turns "rebuilt but not deployed"
    # into a build error. Pure file comparison: no AWS credentials, so this
    # runs in CI before the OIDC step like every other check here.
    stamp_path = ROOT / "infra" / "corpus.deployed.sha256"
    corpus_sha = hashlib.sha256(corpus_path.read_bytes()).hexdigest()
    if not stamp_path.exists():
        failed = True
        print("\nFAIL: infra/corpus.deployed.sha256 is missing.")
        print("  Nothing records which corpus the chatbot is actually running.")
        print("  Deploy it with: infra/deploy-chatbot.sh")
    else:
        deployed_sha = stamp_path.read_text().strip()
        if deployed_sha != corpus_sha:
            failed = True
            print("\nFAIL: infra/corpus.json has not been deployed to the chatbot.")
            print(f"  committed corpus: {corpus_sha}")
            print(f"  deployed corpus:  {deployed_sha}")
            print("  The site would ship while the bot keeps answering from the older corpus.")
            print("  Deploy it with: infra/deploy-chatbot.sh")

    if failed:
        print("\nThe chatbot would answer from stale content. Not shipping it.")
        return 1

    print("OK: corpus matches index.html, its declared model/dimensions, "
          "and the corpus deployed to the Lambda")
    return 0


if __name__ == "__main__":
    sys.exit(main())
