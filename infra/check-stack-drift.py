#!/usr/bin/env python3
"""
Fails if infra/stack.txt and the chip rows describing this site's own
infrastructure in index.html disagree, in either direction.

Two cards carry that now -- "This Website" for how the site is served and
"Delivery & Monitoring Pipeline" for how it ships and alarms -- so the check
is against the union of their chip rows. Which card a chip sits on is a
presentation choice; the set of services the site actually runs on is the
thing worth a tripwire.

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
CARD_HEADINGS = ["<h3>This Website</h3>",
                 "<h3>Delivery &amp; Monitoring Pipeline</h3>"]


def manifest_tokens(path):
    tokens = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            tokens.append(line)
    return tokens


def card_chips(html):
    """Chips from every card describing this site's own stack, in page order.

    Scoped to those cards rather than to the first .stack on the page -- every
    other project card has its own chip row and none of them are this site.
    """
    blocks = html.split('<div class="project">')
    chips, seen = [], set()
    for heading in CARD_HEADINGS:
        for block in blocks:
            if heading in block:
                m = re.search(r'<div class="stack">(.*?)</div>', block, re.S)
                if not m:
                    sys.exit(f"FAIL: found the {heading!r} card but no chip row in it")
                for chip in re.findall(r"<span>([^<]*)</span>", m.group(1)):
                    if chip not in seen:
                        seen.add(chip)
                        chips.append(chip)
                break
        else:
            sys.exit(f"FAIL: no project card containing {heading!r}")
    return chips


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
        print("\nFAIL: in infra/stack.txt but not in any chip row:")
        for t in missing_from_page:
            print(f"  - {t}")
    if missing_from_manifest:
        failed = True
        print("\nFAIL: in a chip row but not in infra/stack.txt:")
        for t in missing_from_manifest:
            print(f"  - {t}")

    if failed:
        print("\nThe cards and the manifest disagree. Update whichever is wrong;")
        print("the deploy will not ship a stale chip row.")
        return 1

    print("OK: chip rows match the manifest exactly")

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
