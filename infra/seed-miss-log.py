#!/usr/bin/env python3
"""Seed the quiz miss log from the markdown log Ryan has been keeping by hand.

Usage:  infra/seed-miss-log.py --sub <cognito-sub> [--apply]

Dry-run by default: prints what it would write and changes nothing. Shells out to the AWS
CLI rather than importing boto3, which is not installed locally.

Only OPEN items are seeded with a due date. Retired ones are carried across too, so the
history is not lost and a retired concept is never re-drilled from scratch.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

LOG = pathlib.Path.home() / "Documents/Claude/AWS AI Practitioner/miss-log.md"
TABLE = "ryangrey-quiz"
LADDER = [1, 3, 7]


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:60]


def parse(path):
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) < 6 or not cells[0].isdigit():
            continue
        _n, date, module, concept, miss, status = cells[:6]
        domain = ""
        m = re.search(r"Domain\s*(\d)", module)
        if m:
            domain = f"D{m.group(1)}"
        retired = status.upper().startswith("RETIRED")
        streak = 0
        m = re.search(r"\((\d)\s*/\s*2", status)
        if m:
            streak = int(m.group(1))
        rows.append({"conceptId": slug(concept), "concept": concept, "rule": miss,
                     "domain": domain, "moduleId": module.split("/")[0].strip(),
                     "status": "RETIRED" if retired else "OPEN",
                     "correctStreak": 2 if retired else streak,
                     "firstMissed": date})
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sub", required=True, help="Cognito sub of the signed-in user")
    ap.add_argument("--apply", action="store_true", help="actually write (default: dry run)")
    args = ap.parse_args()

    if not LOG.exists():
        sys.exit(f"miss log not found: {LOG}")
    rows = parse(LOG)
    now = datetime.now(timezone.utc)

    print(f"parsed {len(rows)} entries from {LOG.name}")
    for r in rows:
        # An open item is due immediately: it is already overdue by the time this runs.
        due = now if r["status"] == "OPEN" else now + timedelta(days=LADDER[-1])
        item = {
            "pk": {"S": f"USER#{args.sub}"},
            "sk": {"S": f"MISS#{r['conceptId']}"},
            "status": {"S": r["status"]},
            "correctStreak": {"N": str(r["correctStreak"])},
            "dueAt": {"S": due.strftime("%Y-%m-%dT%H:%M:%SZ")},
            "concept": {"S": r["concept"][:400]},
            "rule": {"S": r["rule"][:600]},
            "domain": {"S": r["domain"]},
            "moduleId": {"S": r["moduleId"]},
            "seededFrom": {"S": "miss-log.md"},
            "lastMissedAt": {"S": r["firstMissed"]},
        }
        flag = "OPEN " if r["status"] == "OPEN" else "RETIRD"
        print(f"  [{flag}] {r['conceptId']}  streak={r['correctStreak']}  {r['domain'] or '--'}")
        if args.apply:
            subprocess.run(
                ["aws", "dynamodb", "put-item", "--table-name", TABLE,
                 "--item", json.dumps(item)],
                check=True, capture_output=True)
    print("\nwrote to DynamoDB" if args.apply else "\ndry run — pass --apply to write")


if __name__ == "__main__":
    main()
