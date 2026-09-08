#!/usr/bin/env python3
"""Regression checks for public-data rendering and fail-before-upload behavior."""
from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("activity", Path(__file__).with_name("build-github-activity.py"))
activity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(activity)


def calendar_fixture(count=365):
    today = datetime.now(timezone.utc).date()
    cells = []
    for i in range(count):
        day = today - timedelta(days=count - 1 - i)
        cells.append(f'<td data-date="{day}" data-level="0" id="day-{i}"></td>'
                     f'<tool-tip for="day-{i}">No contributions on a day.</tool-tip>')
    return '<h2 id="js-contribution-activity-description">0 contributions in the last year</h2><table>' + ''.join(cells) + '</table>'


class SnapshotTests(unittest.TestCase):
    def test_week_aligned_calendar_and_bounds(self):
        for count in (366, 367, 371):
            self.assertEqual(len(activity.calendar(calendar_fixture(count))['days']), count)
        for count in (364, 372):
            with self.assertRaises(ValueError):
                activity.calendar(calendar_fixture(count))
        source = calendar_fixture(367)
        today = datetime.now(timezone.utc).date()
        with self.assertRaises(ValueError):
            activity.calendar(source.replace(str(today - timedelta(days=1)), str(today)))

    def test_full_year_and_date_labels(self):
        result = activity.calendar(calendar_fixture())
        self.assertEqual(len(result['days']), 365)
        self.assertEqual(result['days'][-1]['date'], datetime.now(timezone.utc).date().isoformat())

    def test_missing_day_and_wrong_total_fail(self):
        source = calendar_fixture()
        with self.assertRaises(ValueError):
            activity.calendar(source.replace('data-date=', 'removed=', 1))
        with self.assertRaises(ValueError):
            activity.calendar(source.replace('0 contributions in', '9 contributions in'))

    def test_external_links_rejected(self):
        for url in ('https://example.com/a', '//example.com/a', 'javascript:alert(1)'):
            with self.assertRaises(ValueError):
                activity.link(activity.Node('a', [('href', url)]))

    def test_remote_text_remains_data_and_scripts_not_copied(self):
        source = '''<div class="contribution-activity-listing"><h3>September 2026</h3>
          <div class="TimelineItem"><summary>Created 1 repository</summary><ul><li>
          <a href="/ryan-grey/example">&lt;img src=x onerror=alert(1)&gt;</a>
          <script>alert(1)</script></li></ul></div></div>'''
        result = activity.activity(source)
        self.assertEqual(result['groups'][0]['rows'][0]['links'][0], {
            'url': 'https://github.com/ryan-grey/example',
            'text': '<img src=x onerror=alert(1)>',
        })
        self.assertNotIn('<script', str(result))

    def test_unexpected_response_fails(self):
        for source in ('<h1>Sign in</h1>', '<div class="contribution-activity-listing"><h3>September 2026</h3></div>'):
            with self.assertRaises(ValueError):
                activity.activity(source)

    def test_empty_month_is_explicit(self):
        result = activity.activity('<div class="contribution-activity-listing"><h3>September 2026</h3><p>No activity yet</p></div>')
        self.assertEqual(result, {'month': 'September 2026', 'groups': []})


if __name__ == '__main__':
    unittest.main()
