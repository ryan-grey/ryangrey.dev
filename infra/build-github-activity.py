#!/usr/bin/env python3
"""Render the public GitHub calendar and current activity into the static homepage.

No credentials are used: only information visible to a signed-out visitor is
published. Fetch and validate everything before replacing the marked section.
GitHub's HTML is not a stable API; unexpected markup fails the deployment before
any upload, leaving the last successful snapshot live.
"""
import argparse
from datetime import date, datetime, timezone
from html import escape
from html.parser import HTMLParser
from pathlib import Path
import re
from urllib.parse import urljoin, urlsplit
from urllib.request import Request, urlopen

PROFILE = "https://github.com/ryan-grey"
START = "    <!-- github-activity:start -->"
END = "    <!-- github-activity:end -->"


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
    return f'<a href="{escape(href, quote=True)}">{escape(node.text())}</a>'


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
    offset = (days[0][0].weekday() + 1) % 7
    width = 42 + ((len(days) + offset + 6) // 7) * 14
    out = [f'<p class="contribution-total">{escape(heading)}</p>',
           '<div class="contribution-calendar" tabindex="0" role="region" aria-label="Contribution calendar; scroll horizontally on small screens">',
           f'<svg class="contribution-graph" viewBox="0 0 {width} 150" role="img" aria-labelledby="contribution-title contribution-desc">',
           f'<title id="contribution-title">{escape(heading)}</title>',
           '<desc id="contribution-desc">Daily contributions from GitHub, with green intensity indicating activity. Open the full GitHub profile for the accessible daily calendar.</desc>']
    for row, name in ((1, "Mon"), (3, "Wed"), (5, "Fri")):
        out.append(f'<text x="0" y="{35 + row * 14}">{name}</text>')
    last_month = None
    for i, (day, level, count) in enumerate(days):
        column, row = divmod(i + offset, 7)
        x, y = 34 + column * 14, 25 + row * 14
        if day.month != last_month and column < (width - 65) // 14:
            out.append(f'<text x="{x}" y="14">{day.strftime("%b")}</text>')
            last_month = day.month
        label = f'{count} contribution{"" if count == 1 else "s"} on {day.isoformat()}'
        out.append(f'<rect class="contribution-level-{level}" x="{x}" y="{y}" width="11" height="11" rx="2"><title>{label}</title></rect>')
    out.append('</svg></div>')
    out.append('<div class="contribution-legend"><a href="https://docs.github.com/en/account-and-profile/reference/profile-contributions-reference">How GitHub counts contributions</a><span>Less ' +
               ''.join(f'<i class="contribution-level-{n}" aria-hidden="true"></i>' for n in range(5)) + ' More</span></div>')
    return '\n'.join(out)


def activity(source):
    root = Document(source).root
    listing = next(root.find(cls="contribution-activity-listing"), None)
    if listing is None:
        raise ValueError("GitHub activity listing is missing")
    month = next(listing.find("h3"), None)
    if month is None:
        raise ValueError("GitHub activity month is missing")
    out = ['<h3 class="activity-heading">Contribution activity</h3>',
           f'<p class="activity-month"><span>{escape(month.text())}</span></p>',
           '<div class="activity-timeline">']
    items = list(listing.find(cls="TimelineItem"))
    for item in items:
        summary = next(item.find("summary"), None)
        if summary is None:
            # Unrecognized activity must not silently disappear from a snapshot.
            raise ValueError("Unsupported GitHub timeline item")
        heading = summary.text()
        out.append('<details class="activity-item"' + (' open' if "repositories" in heading and "commits" not in heading else '') + '>')
        out.append(f'<summary>{escape(heading)}</summary><ul>')
        for row in item.find("li"):
            anchors = list(row.find("a"))
            if not anchors:
                continue
            language = next((n.text() for n in row.find("span")
                             if n.attrs.get("itemprop") == "programmingLanguage"), "")
            when = next(row.find("time"), None)
            out.append('<li><span class="activity-links">' + ' '.join(link(a) for a in anchors) + '</span>')
            if language:
                out.append(f'<span class="activity-language">{escape(language)}</span>')
            if when:
                out.append(f'<span class="activity-date">{escape(when.text())}</span>')
            out.append('</li>')
        out.append('</ul></details>')
    if not items:
        if "no activity" not in listing.text().lower():
            raise ValueError("Unrecognized empty GitHub activity response")
        out.append('<p>No public contribution activity this month.</p>')
    out.append('</div>')
    return '\n'.join(out)


def render(calendar_source, activity_source):
    updated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    return (calendar(calendar_source) + '\n' + activity(activity_source) +
            f'\n<p class="activity-footer">Public GitHub activity · Updated {updated} · '
            f'<a href="{PROFILE}?tab=overview">View full history on GitHub &rarr;</a></p>')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--calendar-file", type=Path)
    parser.add_argument("--activity-file", type=Path)
    parser.add_argument("--fragment", action="store_true", help="Print without editing the homepage")
    args = parser.parse_args()
    cal = args.calendar_file.read_text() if args.calendar_file else fetch("https://github.com/users/ryan-grey/contributions")
    act = args.activity_file.read_text() if args.activity_file else fetch(PROFILE + "?tab=contributions")
    fragment = render(cal, act)
    if args.fragment:
        print(fragment)
        return
    page = Path(__file__).resolve().parent.parent / "index.html"
    source = page.read_text()
    if source.count(START) != 1 or source.count(END) != 1:
        raise ValueError("Expected exactly one contribution snapshot marker pair")
    before, rest = source.split(START)
    _, after = rest.split(END)
    page.write_text(before + START + '\n' + fragment + '\n' + END + after)
    print("Updated public GitHub contribution snapshot")


if __name__ == "__main__":
    main()
