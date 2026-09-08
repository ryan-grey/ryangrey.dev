const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { validate, dayLabel, githubURL } = require('../github-activity.js');

function fixture(count = 365) {
  const end = Date.UTC(2026, 8, 7);
  return {
    schemaVersion: 1, updatedAt: new Date().toISOString(), profile: 'https://github.com/ryan-grey',
    calendar: {total: 1, days: Array.from({length: count}, (_, i) => ({
      date: new Date(end - (count - 1 - i) * 86400000).toISOString().slice(0, 10),
      count: i === count - 1 ? 1 : 0, level: i === count - 1 ? 1 : 0,
    }))}, activity: {month: 'September 2026', groups: []},
  };
}

test('validates a complete feed and formats dates consistently', () => {
  const data = validate(fixture());
  assert.equal(dayLabel(data.calendar.days.at(-1)), '1 contribution on September 7, 2026');
});
test('accepts week-aligned years while retaining size and continuity guards', () => {
  for (const count of [366, 367, 371]) assert.equal(validate(fixture(count)).calendar.days.length, count);
  for (const count of [364, 372]) assert.throws(() => validate(fixture(count)));
  const duplicate = fixture(367);
  duplicate.calendar.days[1].date = duplicate.calendar.days[0].date;
  assert.throws(() => validate(duplicate));
});
test('rejects missing days, impossible dates, and mismatched totals', () => {
  for (const mutate of [d => d.calendar.days.pop(), d => d.calendar.total++,
    d => d.calendar.days[0].date = '2026-02-30', d => d.calendar.days[1].date = d.calendar.days[0].date]) {
    const data = fixture(); mutate(data); assert.throws(() => validate(data));
  }
});
test('rejects foreign and credential-bearing links', () => {
  for (const url of ['javascript:alert(1)', 'https://example.com', 'https://github.com.evil.test/a', 'https://user@github.com/a']) {
    assert.throws(() => githubURL(url));
  }
  assert.equal(githubURL('https://github.com/ryan-grey'), 'https://github.com/ryan-grey');
});
test('validates nested activity before drawing', () => {
  const data = fixture();
  data.activity.groups = [{summary: 'Created 1 repository', rows: [{links: [{url: 'https://evil.test/', text: 'bad'}], language: '', date: ''}]}];
  assert.throws(() => validate(data));
});
test('CSP allows same-origin homepage code without enabling other pages', () => {
  const context = {};
  vm.runInNewContext(fs.readFileSync(require.resolve('./cloudfront-security-headers.js'), 'utf8'), context);
  for (const uri of ['/', '/index.html', '/404.html', '/greybot/privacy/index.html']) {
    const result = context.handler({request: {uri}, response: {headers: {}}});
    const policy = result.headers['content-security-policy'].value;
    const home = uri === '/' || uri === '/index.html';
    assert.ok(policy.includes(`script-src '${home ? 'self' : 'none'}'`));
    assert.ok(policy.includes(`connect-src '${home ? 'self' : 'none'}'`));
    assert.ok(!policy.includes('unsafe-eval'));
    assert.ok(policy.includes("frame-ancestors 'none'"));
    assert.equal(result.headers['x-content-type-options'].value, 'nosniff');
  }
});
