#!/usr/bin/env bash
#
# What is actually causing the 4xx rate.
#
# Reads the S3 server access logs written by setup-access-logs.sh and splits the
# 403s into the two categories that matter:
#
#   - paths a real client asks for on its own (robots.txt, sitemap.xml,
#     favicons, apple-touch-icon variants, .well-known). Every one of these is a
#     bug we can close by putting the file there.
#   - probing for software this site does not run (/wp-login.php and friends).
#     These SHOULD be refused. They are not a defect and the target is not zero.
#
# Remember what this can and cannot see: it is a census of ORIGIN requests. Any
# hit CloudFront served from cache never appears. The 4xx picture is sound
# because 403s cache for only ~10s here; the 2xx picture is not, and a request
# count from this script is not site traffic.
#
# Usage:  AWS_PROFILE=infra ./infra/analyse-access-logs.sh [days]

set -euo pipefail

BUCKET="ryangrey-dev-logs"
PREFIX="s3-origin/"
DAYS="${1:-7}"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo "==> Downloading logs from s3://${BUCKET}/${PREFIX}"
aws s3 sync "s3://${BUCKET}/${PREFIX}" "$WORK/logs" --quiet 2>/dev/null || true
COUNT=$(find "$WORK/logs" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$COUNT" = "0" ]; then
    echo
    echo "No log objects yet. S3 server access logging is best-effort and usually"
    echo "takes a couple of hours for the first delivery. Re-run later."
    exit 0
fi
echo "    $COUNT log files"

cat "$WORK"/logs/* > "$WORK/all.log" 2>/dev/null

python3 - "$WORK/all.log" "$DAYS" <<'PY'
import collections, re, sys

path, days = sys.argv[1], int(sys.argv[2])

# S3 server access log format is space separated with quoted sections. The
# request line is quoted, and the fields after it are operation-dependent, so
# pull what we need by position from a shlex-style split rather than a regex
# over the whole line.
import shlex
rows = []
for line in open(path, errors="replace"):
    try:
        f = shlex.split(line)
    except ValueError:
        continue
    if len(f) < 12:
        continue
    # 7=key 9="METHOD /uri HTTP/1.1" 10=status 11=error-code
    key, request, status = f[7], f[9], f[10]
    uri = request.split(" ")[1] if " " in request else request
    rows.append((uri, status, f[11] if len(f) > 11 else "-"))

if not rows:
    print("No parseable request rows yet.")
    raise SystemExit(0)

total = len(rows)
by_status = collections.Counter(s for _, s, _ in rows)
errors = [(u, s, e) for u, s, e in rows if s.startswith(("4", "5"))]

print(f"\nOrigin requests parsed: {total}")
print("Status breakdown:")
for s, n in by_status.most_common():
    print(f"  {s}  {n:>6}  ({100*n/total:.1f}%)")

if not errors:
    print("\nNo 4xx/5xx at the origin.")
    raise SystemExit(0)

# Things a client asks for without being told to. Each is closeable by adding
# the file; robots.txt and sitemap.xml were closed on 2026-09-01.
AUTO = re.compile(
    r"/(robots\.txt|sitemap\.xml|favicon\.[a-z]+|apple-touch-icon[^/]*|"
    r"browserconfig\.xml|site\.webmanifest|manifest\.json|humans\.txt|"
    r"\.well-known/.*|ads\.txt|security\.txt)$", re.I)

auto, probes = collections.Counter(), collections.Counter()
for uri, status, _ in errors:
    (auto if AUTO.search(uri.split("?")[0]) else probes)[uri.split("?")[0]] += 1

a, p = sum(auto.values()), sum(probes.values())
print(f"\n4xx/5xx at origin: {len(errors)}  ({100*len(errors)/total:.1f}% of origin requests)")
print(f"  self-initiated client requests : {a:>6}  ({100*a/len(errors):.1f}%)   <- closeable, add the file")
print(f"  probing for absent software    : {p:>6}  ({100*p/len(errors):.1f}%)   <- should be refused")

if auto:
    print("\nSelf-initiated, still failing (fix these):")
    for u, n in auto.most_common(15):
        print(f"  {n:>6}  {u}")

print("\nTop probed paths:")
for u, n in probes.most_common(15):
    print(f"  {n:>6}  {u}")
PY
