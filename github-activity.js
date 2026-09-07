/* Public contribution calendar. No libraries, credentials, or third-party calls. */
(() => {
  'use strict';
  const PROFILE = 'https://github.com/ryan-grey';
  const DAY = 86400000;

  function githubURL(value) {
    const url = new URL(value);
    if (url.origin !== 'https://github.com' || url.username || url.password) {
      throw new Error('Unexpected activity link');
    }
    return url.href;
  }

  function dateValue(value) {
    const time = Date.parse(`${value}T00:00:00Z`);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value) || !Number.isFinite(time) ||
        new Date(time).toISOString().slice(0, 10) !== value) {
      throw new Error('Invalid contribution date');
    }
    return time;
  }

  function validate(data) {
    if (data?.schemaVersion !== 1 || data.profile !== PROFILE ||
        !Number.isFinite(Date.parse(data.updatedAt)) ||
        Date.parse(data.updatedAt) > Date.now() + DAY ||
        !Array.isArray(data.calendar?.days) || ![365, 366].includes(data.calendar.days.length) ||
        !Number.isSafeInteger(data.calendar.total) || data.calendar.total < 0 ||
        typeof data.activity?.month !== 'string' || !Array.isArray(data.activity.groups)) {
      throw new Error('Invalid contribution feed');
    }
    let previous = null;
    let total = 0;
    for (const day of data.calendar.days) {
      const time = dateValue(day.date);
      if ((previous !== null && time - previous !== DAY) ||
          !Number.isInteger(day.level) || day.level < 0 || day.level > 4 ||
          !Number.isSafeInteger(day.count) || day.count < 0) {
        throw new Error('Invalid contribution day');
      }
      previous = time;
      total += day.count;
    }
    if (total !== data.calendar.total) throw new Error('Contribution total mismatch');
    for (const group of data.activity.groups) {
      if (typeof group.summary !== 'string' || !Array.isArray(group.rows)) throw new Error('Invalid activity');
      for (const row of group.rows) {
        if (!Array.isArray(row.links) || typeof row.language !== 'string' || typeof row.date !== 'string') {
          throw new Error('Invalid activity row');
        }
        for (const link of row.links) {
          githubURL(link.url);
          if (typeof link.text !== 'string') throw new Error('Invalid activity label');
        }
      }
    }
    return data;
  }

  function dayLabel(day) {
    const date = new Date(dateValue(day.date)).toLocaleDateString('en-US', {
      year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC',
    });
    return `${day.count.toLocaleString('en-US')} contribution${day.count === 1 ? '' : 's'} on ${date}`;
  }

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { validate, dateValue, dayLabel, githubURL };
  }
  if (typeof document === 'undefined') return;
  const root = document.getElementById('github-activity');
  if (!root) return;
  const content = document.getElementById('github-content');
  const status = document.getElementById('github-status');
  const refresh = document.getElementById('github-refresh');
  let current = null;
  let pending = false;
  let lastCheck = 0;

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function svgNode(tag, attrs, text) {
    const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
    for (const [name, value] of Object.entries(attrs)) node.setAttribute(name, value);
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function anchor(text, url, className) {
    const node = element('a', className, text);
    node.href = githubURL(url);
    return node;
  }

  function draw(data) {
    // Build off-screen; a malformed response never replaces a working view.
    const fragment = document.createDocumentFragment();
    fragment.append(element('p', 'contribution-total', `${data.calendar.total.toLocaleString('en-US')} contributions in the last year`));
    const calendar = element('div', 'contribution-calendar');
    calendar.setAttribute('role', 'region');
    calendar.setAttribute('aria-label', 'Daily contributions; use arrow keys to explore days');
    const days = data.calendar.days;
    const offset = new Date(dateValue(days[0].date)).getUTCDay();
    const columns = Math.ceil((days.length + offset) / 7);
    const width = 42 + columns * 14;
    const svg = svgNode('svg', {class: 'contribution-graph', viewBox: `0 0 ${width} 132`, role: 'group', 'aria-label': 'Contribution calendar'});
    for (const [row, name] of [[1, 'Mon'], [3, 'Wed'], [5, 'Fri']]) {
      svg.append(svgNode('text', {x: 0, y: 35 + row * 14, 'aria-hidden': 'true'}, name));
    }
    const dayInfo = element('p', 'contribution-day-info', 'Hover, tap, or use arrow keys to explore a day.');
    dayInfo.id = 'contribution-day-info';
    const cells = [];
    let month = '';
    let focused = days.length - 1;
    const select = index => {
      cells[focused].setAttribute('tabindex', '-1');
      focused = index;
      cells[focused].setAttribute('tabindex', '0');
      dayInfo.replaceChildren(anchor(`${dayLabel(days[index])} →`,
        `${PROFILE}?tab=overview&from=${days[index].date}&to=${days[index].date}`));
    };
    days.forEach((day, i) => {
      const column = Math.floor((i + offset) / 7);
      const row = (i + offset) % 7;
      const x = 34 + column * 14;
      const monthKey = day.date.slice(0, 7);
      if (monthKey !== month && column < columns - 2) {
        svg.append(svgNode('text', {x, y: 14, 'aria-hidden': 'true'},
          new Date(dateValue(day.date)).toLocaleDateString('en-US', {month: 'short', timeZone: 'UTC'})));
        month = monthKey;
      }
      const cell = svgNode('rect', {
        class: `contribution-level-${day.level}`, x, y: 25 + row * 14,
        width: 11, height: 11, rx: 2, tabindex: i === focused ? 0 : -1,
        role: 'button', 'aria-label': dayLabel(day),
      });
      cell.append(svgNode('title', {}, dayLabel(day)));
      cell.addEventListener('pointerenter', () => select(i));
      cell.addEventListener('focus', () => select(i));
      cell.addEventListener('click', () => { select(i); cell.focus(); });
      cell.addEventListener('keydown', event => {
        const moves = {ArrowLeft: -7, ArrowRight: 7, ArrowUp: -1, ArrowDown: 1};
        if (event.key in moves) {
          event.preventDefault();
          const next = Math.max(0, Math.min(days.length - 1, i + moves[event.key]));
          select(next);
          cells[next].focus();
          cells[next].scrollIntoView({block: 'nearest', inline: 'nearest'});
        } else if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          select(i);
        }
      });
      cells.push(cell);
      svg.append(cell);
    });
    calendar.append(svg);
    fragment.append(calendar);
    const legend = element('div', 'contribution-legend');
    const guide = element('a', '', 'How GitHub counts contributions');
    guide.href = 'https://docs.github.com/en/account-and-profile/reference/profile-contributions-reference';
    const scale = element('span', '', 'Less ');
    for (let i = 0; i < 5; i++) {
      const swatch = element('i', `contribution-level-${i}`);
      swatch.setAttribute('aria-hidden', 'true');
      scale.append(swatch);
    }
    scale.append(document.createTextNode(' More'));
    legend.append(guide, scale);
    fragment.append(legend, dayInfo, element('h3', 'activity-heading', 'Contribution activity'));
    const monthLine = element('p', 'activity-month');
    monthLine.append(element('span', '', data.activity.month));
    fragment.append(monthLine);
    const timeline = element('div', 'activity-timeline');
    for (const group of data.activity.groups) {
      const details = element('details', 'activity-item');
      details.open = /repositories/.test(group.summary) && !/commits/.test(group.summary);
      details.append(element('summary', '', group.summary));
      const list = element('ul');
      for (const row of group.rows) {
        const item = element('li');
        const links = element('span', 'activity-links');
        for (const link of row.links) links.append(anchor(link.text, link.url));
        item.append(links);
        if (row.language) item.append(element('span', 'activity-language', row.language));
        if (row.date) item.append(element('span', 'activity-date', row.date));
        list.append(item);
      }
      details.append(list);
      timeline.append(details);
    }
    if (!data.activity.groups.length) timeline.append(element('p', '', 'No public contribution activity this month.'));
    fragment.append(timeline);
    content.replaceChildren(fragment);
    // Show recent activity first on narrow screens, without moving the page.
    calendar.scrollLeft = calendar.scrollWidth;
  }

  function freshness(data) {
    const updated = new Date(data.updatedAt);
    const label = updated.toLocaleString('en-US', {month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'});
    return `${Date.now() - updated.getTime() > 18 * 3600000 ? 'Updates delayed. ' : ''}Public GitHub data · Updated ${label} · Synced every six hours.`;
  }

  async function load() {
    if (pending) return;
    pending = true;
    refresh.disabled = true;
    status.textContent = current ? 'Checking for updated activity…' : 'Loading GitHub activity…';
    try {
      const response = await fetch('/github-activity.json', {
        cache: 'no-cache', credentials: 'omit', signal: AbortSignal.timeout(12000),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = validate(await response.json());
      if (!current || current.updatedAt !== data.updatedAt) draw(data);
      current = data;
      lastCheck = Date.now();
      status.textContent = freshness(data);
    } catch {
      status.textContent = current
        ? `Could not refresh; showing the previous data. ${freshness(current)}`
        : 'GitHub activity is unavailable right now. Try again or view the full GitHub profile below.';
    } finally {
      refresh.disabled = false;
      refresh.hidden = false;
      pending = false;
    }
  }
  refresh.addEventListener('click', load);
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && Date.now() - lastCheck > 15 * 60000) load();
  });
  load();
})();
