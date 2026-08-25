#!/usr/bin/env python3
"""
Fails if infra/stack.txt and the "This Website" chip row in index.html
disagree, in either direction.

The site has no build step, so the chip row is hand-written. It describes
the same system as the CV and the README, and it drifted once already --
capabilities were added to the card while the chips still listed the
original stack. The CV and README change rarely and deliberately; chips
change incidentally, and incidental edits are the ones that need a
tripwire.

This extends the contract the deploy already enforces: a green run means
the site is consistent, not merely uploaded.

Usage: python3 infra/check-stack-drift.py [--readme]
Exit 0 if consistent, 1 otherwise.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CARD_HEADING = "<h3>This Website</h3>"


def manifest_tokens(path):
    tokens = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            tokens.append(line)
    return tokens


def card_chips(html):
    """Chips from the project card containing CARD_HEADING, not just the
    first .stack on the page -- other cards have their own chip rows."""
    blocks = html.split('<div class="project">')
    for block in blocks:
        if CARD_HEADING in block:
            m = re.search(r'<div class="stack">(.*?)</div>', block, re.S)
            if not m:
                sys.exit('FAIL: found the "This Website" card but no chip row in it')
            return re.findall(r"<span>([^<]*)</span>", m.group(1))
    sys.exit(f"FAIL: no project card containing {CARD_HEADING!r}")


def main():
    manifest = manifest_tokens(ROOT / "infra" / "stack.txt")
    html = (ROOT / "index.html").read_text(encoding="utf-8")
    chips = card_chips(html)

    missing_from_page = [t for t in manifest if t not in chips]
    missing_from_manifest = [c for c in chips if c not in manifest]

    print(f"manifest: {len(manifest)} tokens")
    print(f"chip row: {len(chips)} chips")

    failed = False
    if missing_from_page:
        failed = True
        print("\nFAIL: in infra/stack.txt but not in the chip row:")
        for t in missing_from_page:
            print(f"  - {t}")
    if missing_from_manifest:
        failed = True
        print("\nFAIL: in the chip row but not in infra/stack.txt:")
        for t in missing_from_manifest:
            print(f"  - {t}")

    if failed:
        print("\nThe card and the manifest disagree. Update whichever is wrong;")
        print("the deploy will not ship a stale chip row.")
        return 1

    print("OK: chip row matches the manifest exactly")

    # Advisory only -- prose uses different word forms than chip labels, so a
    # hard check here would fail on wording rather than on real drift.
    if "--readme" in sys.argv:
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        unmentioned = [t for t in manifest if t.lower() not in readme.lower()]
        if unmentioned:
            print("\nadvisory: not mentioned verbatim in README.md "
                  "(may be fine -- prose wording differs):")
            for t in unmentioned:
                print(f"  ? {t}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
