#!/usr/bin/env python3
"""Fetch the portfolio and verify every referenced asset loads."""
import argparse
import re
import sys
import urllib.error
import urllib.request
from urllib.parse import urljoin

PAGES = ["/"]

ASSET = re.compile(r'<(?:script|link|img)\b[^>]*?\b(?:src|href)\s*=\s*"([^"]+)"', re.I)
OG_IMAGE = re.compile(r'<meta\b[^>]*?property="og:image"[^>]*?content="([^"]+)"', re.I)
SKIP = ("data:", "mailto:", "#", "http://", "https://")


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "check-page-assets"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.status, r.read().decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="https://ryangrey.dev")
    args = ap.parse_args()
    base = args.base.rstrip("/")

    failures = []
    for path in PAGES:
        page_url = base + path
        try:
            status, html = get(page_url)
        except urllib.error.HTTPError as e:
            failures.append(f"{page_url} -> HTTP {e.code}")
            continue
        print(f"{page_url} -> {status}")

        for ref in ASSET.findall(html):
            if ref.startswith(SKIP):
                continue
            # Resolve exactly as a browser would: against the document URL,
            # trailing slash and all.
            target = urljoin(page_url, ref)
            try:
                code, _ = get(target)
                print(f"    {ref:<24} -> {target}  {code}")
            except urllib.error.HTTPError as e:
                print(f"    {ref:<24} -> {target}  HTTP {e.code}")
                failures.append(f"{page_url} references {ref!r}, which resolves "
                                f"to {target} and returns HTTP {e.code}")

        # og:image is fetched by scrapers, not by the page, so no amount of
        # browsing the site reveals a broken one -- the card just renders
        # without a picture, days later, in someone else's feed. It must also
        # be ABSOLUTE: LinkedIn ignores a relative og:image outright.
        for ref in OG_IMAGE.findall(html):
            if not ref.startswith("https://"):
                failures.append(f"{page_url} has a non-absolute og:image "
                                f"({ref!r}); scrapers require a full https URL")
                continue
            try:
                code, _ = get(ref)
                print(f"    {'og:image':<24} -> {ref}  {code}")
            except urllib.error.HTTPError as e:
                print(f"    {'og:image':<24} -> {ref}  HTTP {e.code}")
                failures.append(f"{page_url} og:image {ref} returns HTTP {e.code}")

    print()
    if failures:
        print("FAIL: assets that do not load from the page that references them:")
        for f in failures:
            print(f"  {f}")
        print("\nUse an absolute path (/image.png), not a relative one.")
        return 1
    print("OK: every referenced asset loads from every URL the page is served at")
    return 0


if __name__ == "__main__":
    sys.exit(main())
