#!/usr/bin/env python3
"""Build the public JSON feed for the browser contribution tracker.

No credentials are used: only information visible to a signed-out visitor is
published. Fetch and validate everything before replacing the JSON feed.
GitHub's HTML is not a stable API; unexpected markup fails the deployment before
any upload, leaving the last successful snapshot live.
"""
import argparse
from datetime import date, datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
import re
import json
from urllib.parse import urljoin, urlsplit
from urllib.request import Request, urlopen

PROFILE = "https://github.com/ryan-grey"


class Node:
    def __init__(self, tag="", attrs=()):
        self.tag, self.attrs, self.children = tag, dict(attrs), []

    def find(self, tag=None, cls=None):
        for child in self.children:
            if isinstance(child, Node):
                if (tag is None or child.tag == tag) and (
                    cls is None or cls in child.attrs.get("class", "").split()
                ):
                    yield child
                yield from child.find(tag, cls)

    def text(self):
        return " ".join(" ".join(
            c.text() if isinstance(c, Node) else c for c in self.children
        ).split())


class Document(HTMLParser):
    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.root = Node()
        self.stack = [self.root]
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        node = Node(tag, attrs)
        self.stack[-1].children.append(node)
        if tag not in {"area", "base", "br", "col", "embed", "hr", "img",
                       "input", "link", "meta", "param", "source", "track", "wbr"}:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                break

    def handle_data(self, data):
        self.stack[-1].children.append(data)


def fetch(url):
    request = Request(url, headers={
        "User-Agent": "ryangrey.dev contribution snapshot",
        "Accept": "text/html", "Accept-Language": "en-US",
        "X-Requested-With": "XMLHttpRequest",
    })
    with urlopen(request, timeout=25) as response:
        if response.status != 200:
            raise ValueError("GitHub returned an unsuccessful response")
        return response.read(2_000_001).decode("utf-8")


def link(node):
    href = urljoin(PROFILE, node.attrs.get("href", ""))
    parsed = urlsplit(href)
    if parsed.scheme != "https" or parsed.netloc != "github.com":
        raise ValueError("Unexpected activity link origin")
    return {"url": href, "text": node.text()}


def calendar(source):
    root = Document(source).root
    heading = next(n.text() for n in root.find("h2")
                   if n.attrs.get("id") == "js-contribution-activity-description")
    if not re.fullmatch(r"[\d,]+ contributions? in the last year", heading):
        raise ValueError("Missing yearly contribution count")
    tooltips = {n.attrs.get("for"): n.text() for n in root.find("tool-tip")}
    days = []
    for n in root.find("td"):
        if "data-date" not in n.attrs:
            continue
        day = date.fromisoformat(n.attrs["data-date"])
        level = int(n.attrs["data-level"])
        tooltip = tooltips[n.attrs["id"]]
        count = re.match(r"(No|[\d,]+) contributions? on ", tooltip)
        if level not in range(5) or not count:
            raise ValueError("Unexpected calendar cell")
        days.append((day, level, 0 if count[1] == "No" else int(count[1].replace(",", ""))))
    days.sort()
    if len(days) not in (365, 366) or any(
        (b[0] - a[0]).days != 1 for a, b in zip(days, days[1:])
    ):
        raise ValueError("Calendar is incomplete or has duplicate dates")
    if sum(d[2] for d in days) != int(heading.split()[0].replace(",", "")):
        raise ValueError("Calendar total disagrees with daily counts")
    if abs((datetime.now(timezone.utc).date() - days[-1][0]).days) > 2:
        raise ValueError("GitHub calendar is stale")
    return {"total": sum(d[2] for d in days), "days": [
        {"date": day.isoformat(), "level": level, "count": count}
        for day, level, count in days
    ]}


def activity(source):
    root = Document(source).root
    listing = next(root.find(cls="contribution-activity-listing"), None)
    if listing is None:
        raise ValueError("GitHub activity listing is missing")
    month = next(listing.find("h3"), None)
    if month is None:
        raise ValueError("GitHub activity month is missing")
    groups = []
    items = list(listing.find(cls="TimelineItem"))
    for item in items:
        summary = next(item.find("summary"), None)
        if summary is None:
            raise ValueError("Unsupported GitHub timeline item")
        rows = []
        for row in item.find("li"):
            anchors = list(row.find("a"))
            if not anchors:
                continue
            language = next((n.text() for n in row.find("span")
                             if n.attrs.get("itemprop") == "programmingLanguage"), "")
            when = next(row.find("time"), None)
            rows.append({"links": [link(a) for a in anchors],
                         "language": language, "date": when.text() if when else ""})
        groups.append({"summary": summary.text(), "rows": rows})
    if not items and "no activity" not in listing.text().lower():
        raise ValueError("Unrecognized empty GitHub activity response")
    return {"month": month.text(), "groups": groups}


def build(calendar_source, activity_source):
    return {"schemaVersion": 1,
            "updatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "profile": PROFILE,
            "calendar": calendar(calendar_source),
            "activity": activity(activity_source)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--calendar-file", type=Path)
    parser.add_argument("--activity-file", type=Path)
    parser.add_argument("--output", type=Path,
                        default=Path(__file__).resolve().parent.parent / "github-activity.json")
    args = parser.parse_args()
    cal = args.calendar_file.read_text() if args.calendar_file else fetch("https://github.com/users/ryan-grey/contributions")
    act = args.activity_file.read_text() if args.activity_file else fetch(PROFILE + "?tab=contributions")
    data = build(cal, act)
    args.output.write_text(json.dumps(data, separators=(",", ":")) + "\n")
    print("Updated public GitHub contribution feed")


if __name__ == "__main__":
    main()
