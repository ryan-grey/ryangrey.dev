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
# ---------------------------------------------------------------------------
# SYNTHETIC TRAFFIC IS EXCLUDED BY TIME, BECAUSE NOTHING ELSE CAN EXCLUDE IT
#
# On 2026-09-01, while setting this up, 18 requests were fired by hand at paths
# like /wp-login.php and /favicon.png to prove the categoriser worked. They are
# indistinguishable from real traffic in these logs, and that is not an oversight
# to fix: the default cache policy forwards neither query strings
# (QueryStringBehavior: none) nor headers (HeaderBehavior: none) to the origin,
# and the remote IP on every row is a CloudFront edge rather than the viewer. So
# there is no marker to filter on -- not a query parameter, not a User-Agent.
#
# Hence CUTOFF: rows at or before it are dropped. The site takes ~4k requests a
# day, so a few hours of waiting replaces the discarded sample many times over.
# Do NOT lower this to "get more data" -- it would silently mix hand-fired
# requests into the very number this script exists to establish honestly.
# ---------------------------------------------------------------------------
#
# Usage:  AWS_PROFILE=infra ./infra/analyse-access-logs.sh [days]

set -euo pipefail

BUCKET="ryangrey-dev-logs"
PREFIX="s3-origin/"
DAYS="${1:-7}"
CUTOFF="2026-09-01T01:49:36Z"

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

python3 - "$WORK/all.log" "$DAYS" "$CUTOFF" <<'PY'
import collections, datetime, re, sys

path, days, cutoff_s = sys.argv[1], int(sys.argv[2]), sys.argv[3]
cutoff = datetime.datetime.strptime(cutoff_s, "%Y-%m-%dT%H:%M:%SZ").replace(
    tzinfo=datetime.timezone.utc)

# S3 server access log format is space separated with quoted sections. The
# request line is quoted, and the fields after it are operation-dependent, so
# pull what we need by position from a shlex-style split rather than a regex
# over the whole line.
import shlex
rows, dropped = [], 0
for line in open(path, errors="replace"):
    try:
        f = shlex.split(line)
    except ValueError:
        continue
    if len(f) < 12:
        continue
    # 2="[06/Feb/2026:12:00:00 +0000]" 7=key 9="METHOD /uri HTTP/1.1" 10=status
    try:
        when = datetime.datetime.strptime(f[2].strip("[]"), "%d/%b/%Y:%H:%M:%S %z")
    except ValueError:
        continue
    if when <= cutoff:
        dropped += 1
        continue
    request, status = f[9], f[10]
    uri = request.split(" ")[1] if " " in request else request
    rows.append((uri, status, f[11] if len(f) > 11 else "-"))

if dropped:
    print(f"(excluded {dropped} rows at or before {cutoff_s} — hand-fired setup traffic)")
if not rows:
    print("\nNo rows after the cutoff yet. Real traffic accumulates at ~4k/day;")
    print("re-run in an hour or two.")
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
