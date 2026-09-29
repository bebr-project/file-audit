const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

const state = {
  events: [],
  rawEvents: [],
  status: null,
  connected: false,
  demo: true,
  period: '24h',
  view: 'overview',
  updatedAt: Date.now()
};

const sampleEvents = createSampleEvents();

function createSampleEvents() {
  const now = Date.now();
  const records = [
    ['m.sokolova', 'Анна Соколова', 'А.С.', 'Отчёт по продажам.xlsx', 'D:\\Shared\\Финансы\\Отчёт по продажам.xlsx', 'Изменение', 3, 'EXCEL.EXE'],
    ['i.ivanov', 'Илья Иванов', 'И.И.', 'Договор поставки №184.docx', 'D:\\Shared\\Договоры\\Договор поставки №184.docx', 'Изменение', 17, 'WINWORD.EXE'],
    ['e.petrov', 'Елена Петрова', 'Е.П.', 'План разработки.pdf', 'D:\\Shared\\Проекты\\План разработки.pdf', 'Дополнение', 42, 'Acrobat.exe'],
    ['a.smirnov', 'Алексей Смирнов', 'А.С.', 'Бюджет Q4.xlsx', 'D:\\Shared\\Финансы\\Бюджет Q4.xlsx', 'Изменение', 86, 'EXCEL.EXE'],
    ['n.orlova', 'Наталья Орлова', 'Н.О.', 'Презентация продукта.pptx', 'D:\\Shared\\Маркетинг\\Презентация продукта.pptx', 'Изменение', 134, 'POWERPNT.EXE'],
    ['i.ivanov', 'Илья Иванов', 'И.И.', 'Техническое задание.docx', 'D:\\Shared\\Проекты\\Техническое задание.docx', 'Дополнение', 211, 'WINWORD.EXE'],
    ['d.kuznetsov', 'Дмитрий Кузнецов', 'Д.К.', 'Реестр поставщиков.xlsx', 'D:\\Shared\\Закупки\\Реестр поставщиков.xlsx', 'Изменение', 289, 'EXCEL.EXE'],
    ['m.sokolova', 'Анна Соколова', 'А.С.', 'Акт сверки №29.pdf', 'D:\\Shared\\Финансы\\Акт сверки №29.pdf', 'Изменение', 365, 'Acrobat.exe'],
    ['v.fedorova', 'Виктория Фёдорова', 'В.Ф.', 'Регламент отдела.docx', 'D:\\Shared\\Персонал\\Регламент отдела.docx', 'Удаление', 488, 'explorer.exe'],
    ['e.petrov', 'Елена Петрова', 'Е.П.', 'План разработки.pdf', 'D:\\Shared\\Проекты\\План разработки.pdf', 'Изменение', 617, 'Acrobat.exe'],
    ['a.smirnov', 'Алексей Смирнов', 'А.С.', 'Штатное расписание.xlsx', 'D:\\Shared\\Персонал\\Штатное расписание.xlsx', 'Изменение', 754, 'EXCEL.EXE'],
    ['n.orlova', 'Наталья Орлова', 'Н.О.', 'Медиаплан Q4.xlsx', 'D:\\Shared\\Маркетинг\\Медиаплан Q4.xlsx', 'Дополнение', 893, 'EXCEL.EXE'],
    ['d.kuznetsov', 'Дмитрий Кузнецов', 'Д.К.', 'Спецификация.docx', 'D:\\Shared\\Закупки\\Спецификация.docx', 'Изменение', 1045, 'WINWORD.EXE'],
    ['m.sokolova', 'Анна Соколова', 'А.С.', 'Отчёт по продажам.xlsx', 'D:\\Shared\\Финансы\\Отчёт по продажам.xlsx', 'Изменение', 1211, 'EXCEL.EXE'],
    ['e.petrov', 'Елена Петрова', 'Е.П.', 'Роадмап проекта.pdf', 'D:\\Shared\\Проекты\\Роадмап проекта.pdf', 'Изменение', 1432, 'Acrobat.exe'],
    ['i.ivanov', 'Илья Иванов', 'И.И.', 'Протокол встречи.docx', 'D:\\Shared\\Проекты\\Протокол встречи.docx', 'Дополнение', 1730, 'WINWORD.EXE'],
    ['v.fedorova', 'Виктория Фёдорова', 'В.Ф.', 'Оффер — шаблон.docx', 'D:\\Shared\\Персонал\\Оффер — шаблон.docx', 'Изменение', 2241, 'WINWORD.EXE'],
    ['a.smirnov', 'Алексей Смирнов', 'А.С.', 'Траты по подразделениям.csv', 'D:\\Shared\\Финансы\\Траты по подразделениям.csv', 'Изменение', 3155, 'EXCEL.EXE']
  ];
  return records.map(([account, display, initials, file, path, operation, minutes, process], index) => ({
    id: `demo-${index}`,
    time: new Date(now - minutes * 60_000).toISOString(),
    user: account,
    displayName: display,
    initials,
    path,
    operation,
    process,
    computer: 'SRV-FILE-01',
    domain: 'CORP',
    eventId: operation === 'Удаление' ? 4660 : 4663,
    recordId: index + 1
  }));
}

function escapeHtml(value = '') {
  return String(value).replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch]);
}

function basename(path = '') {
  return String(path).split(/[\\/]/).filter(Boolean).at(-1) || String(path || 'Без имени');
}

function getExtension(path = '') {
  const match = basename(path).match(/\.([a-z\d]{1,8})$/i);
  return match ? match[1].toLowerCase() : 'file';
}

function extensionLabel(extension) {
  const labels = { docx: 'DOC', doc: 'DOC', xlsx: 'XLS', xls: 'XLS', xlsm: 'XLS', csv: 'CSV', pdf: 'PDF', pptx: 'PPT', ppt: 'PPT', txt: 'TXT', rtf: 'RTF', odt: 'ODT', ods: 'ODS', odp: 'ODP' };
  return labels[extension] || extension.slice(0, 4).toUpperCase();
}

function classForExtension(extension) {
  if (extension === 'pdf') return 'is-pdf';
  if (['xlsx', 'xls', 'xlsm'].includes(extension)) return 'is-xlsx';
  if (extension === 'csv') return 'is-csv';
  if (['ppt', 'pptx'].includes(extension)) return 'is-pptx';
  return '';
}

function initialsFor(event) {
  if (event.initials) return event.initials;
  const name = event.displayName || event.user || '?';
  return name.split(/[\\.@\s_-]+/).filter(Boolean).slice(0, 2).map(part => part[0]?.toLocaleUpperCase('ru-RU') || '').join('') || '?';
}

function displayUser(event) {
  return event.displayName || event.user || 'Неизвестный пользователь';
}

function displayAccount(event) {
  const account = event.user || 'учётная запись';
  return event.domain && !String(account).includes('\\') ? `${event.domain}\\${account}` : account;
}

function consolidateEvents(events) {
  const groups = [];
  const latestByFile = new Map();
  const sorted = [...events].sort((a, b) => new Date(b.time).getTime() - new Date(a.time).getTime());
  for (const event of sorted) {
    const time = new Date(event.time).getTime();
    const operation = event.eventId === 4660 || event.operation === 'Удаление'
      ? 'Удаление'
      : event.operation === 'Операция с именем' ? 'Операция с именем' : 'Запись';
    const key = [event.computer, event.domain, event.user, String(event.path || '').toLocaleLowerCase('ru-RU'), event.process, operation].join('\u0000');
    const previous = latestByFile.get(key);
    if (!previous || !Number.isFinite(time) || previous.newestTime - time > 2_000) {
      const group = {
        ...event,
        operation,
        rawCount: 1,
        recordIds: [event.recordId].filter(value => value != null),
        eventIds: [event.eventId].filter(value => value != null),
        newestTime: time
      };
      groups.push(group);
      latestByFile.set(key, group);
      continue;
    }
    previous.rawCount += 1;
    if (event.recordId != null) previous.recordIds.push(event.recordId);
    if (event.eventId != null && !previous.eventIds.includes(event.eventId)) previous.eventIds.push(event.eventId);
  }
  return groups.map(({ newestTime, ...group }) => group);
}

function dateParts(input) {
  const date = new Date(input);
  if (Number.isNaN(date.getTime())) return { time: '—', date: 'Неизвестно', full: 'Неизвестная дата' };
  const today = new Date();
  const yesterday = new Date();
  yesterday.setDate(today.getDate() - 1);
  const isSameDay = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  const dateLabel = isSameDay(date, today) ? 'сегодня' : isSameDay(date, yesterday) ? 'вчера' : new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'short' }).format(date);
  return {
    time: new Intl.DateTimeFormat('ru-RU', { hour: '2-digit', minute: '2-digit' }).format(date),
    date: dateLabel,
    full: new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'long', year: 'numeric', hour: '2-digit', minute: '2-digit' }).format(date)
  };
}

function periodStart(period = state.period) {
  if (period === 'all') return 0;
  const duration = period === '7d' ? 7 * 86_400_000 : period === '30d' ? 30 * 86_400_000 : 86_400_000;
  return Date.now() - duration;
}

function inPeriod(event, period = state.period) {
  const time = new Date(event.time).getTime();
  return !Number.isNaN(time) && time >= periodStart(period);
}

function visibleEvents({ search = '', operation = 'all', period = state.period } = {}) {
  const normalized = search.trim().toLocaleLowerCase('ru-RU');
  return state.events.filter(event => {
    if (!inPeriod(event, period)) return false;
    if (operation !== 'all' && event.operation !== operation) return false;
    if (!normalized) return true;
    const searchable = [event.path, basename(event.path), event.user, event.displayName, event.domain, event.computer, event.process, event.operation].join(' ').toLocaleLowerCase('ru-RU');
    return searchable.includes(normalized);
  }).sort((a, b) => new Date(b.time).getTime() - new Date(a.time).getTime());
}

function tableRow(event) {
  const file = basename(event.path);
  const ext = getExtension(event.path);
  const directory = String(event.path || '').replace(/[\\/][^\\/]*$/, '') || '\\';
  const date = dateParts(event.time);
  const badgeClass = event.operation === 'Удаление' ? 'is-delete' : event.operation === 'Операция с именем' ? 'is-ambiguous' : '';
  const operationLabel = event.operation === 'Запись' ? 'Запись в файл' : event.operation === 'Удаление' ? 'Удаление файла' : event.operation || 'Доступ';
  const hint = event.operation === 'Операция с именем'
    ? 'Старое событие Windows 4663: могло сопровождать переименование или удаление'
    : event.rawCount > 1 ? `Объединено событий Windows: ${event.rawCount}` : event.operation === 'Запись' ? 'Windows зафиксировала использование права записи; создание и изменение файла не различаются' : '';
  const operationHint = hint ? ` title="${escapeHtml(hint)}"` : '';
  const host = event.computer || 'Локальный сервер';
  const app = event.process ? ` title="Процесс: ${escapeHtml(event.process)}"` : '';
  return `<tr${app}>
    <td><div class="file-cell"><span class="file-icon ${classForExtension(ext)}" aria-hidden="true">${escapeHtml(extensionLabel(ext))}</span><span class="file-meta"><strong title="${escapeHtml(file)}">${escapeHtml(file)}</strong><span title="${escapeHtml(directory)}">${escapeHtml(directory)}</span></span></div></td>
    <td><div class="user-cell"><span class="user-avatar" aria-hidden="true">${escapeHtml(initialsFor(event))}</span><span class="user-name"><strong title="${escapeHtml(displayUser(event))}">${escapeHtml(displayUser(event))}</strong><span title="${escapeHtml(displayAccount(event))}">${escapeHtml(displayAccount(event))}</span></span></div></td>
    <td><span class="operation-badge ${badgeClass}"${operationHint}>${escapeHtml(operationLabel)}</span></td>
    <td class="time-cell" title="${escapeHtml(date.full)}">${escapeHtml(date.time)}<span>${escapeHtml(date.date)}</span></td>
    <td class="computer-cell">${escapeHtml(host)}</td>
  </tr>`;
}

function renderTable(bodySelector, emptySelector, events, maxRows, isConnectedEmpty) {
  const body = $(bodySelector);
  const empty = $(emptySelector);
  if (!body || !empty) return;
  const pageEvents = events.slice(0, maxRows);
  body.innerHTML = pageEvents.map(tableRow).join('');
  const hasEvents = pageEvents.length > 0;
  empty.hidden = hasEvents;
  if (!hasEvents && isConnectedEmpty) {
    const title = $('#empty-title');
    const copy = $('#empty-copy');
    if (title) title.textContent = state.events.length ? 'Ничего не найдено' : 'Действий пока нет';
    if (copy) copy.textContent = state.events.length ? 'Измените запрос или сбросьте фильтры.' : 'Когда пользователь изменит файл, запись появится здесь.';
  }
}

function chartBuckets(events, period = state.period) {
  const now = Date.now();
  const count = 12;
  const durations = { '24h': 86_400_000, '7d': 7 * 86_400_000, '30d': 30 * 86_400_000, all: 30 * 86_400_000 };
  const duration = durations[period] || durations['24h'];
  const eventTimes = events.map(event => new Date(event.time).getTime()).filter(Number.isFinite);
  const start = period === 'all' ? Math.min(...eventTimes, now - duration) : now - duration;
  const step = Math.max(1, (now - start) / count || duration / count);
  const bars = Array.from({ length: count }, (_, index) => {
    const date = new Date(start + step * index);
    const label = period === '24h'
      ? `${String(date.getHours()).padStart(2, '0')}:00`
      : period === '7d'
        ? new Intl.DateTimeFormat('ru-RU', { weekday: 'short' }).format(date).replace('.', '')
        : new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'short' }).format(date);
    return { label, value: 0 };
  });
  for (const event of events) {
    const time = new Date(event.time).getTime();
    if (!Number.isFinite(time) || time < start || time > now) continue;
    const index = Math.min(count - 1, Math.max(0, Math.floor((time - start) / step)));
    bars[index].value += 1;
  }
  return bars;
}

function renderChart() {
  const filtered = state.events.filter(event => inPeriod(event));
  const buckets = chartBuckets(filtered);
  const max = Math.max(1, ...buckets.map(bucket => bucket.value));
  const chart = $('#activity-chart');
  chart.innerHTML = buckets.map(({ label, value }) => `<div class="chart-column"><div class="bar-track"><span class="chart-bar ${value ? '' : 'is-muted'}" data-height="${value ? Math.max(8, value / max * 100) : 3}" title="${escapeHtml(label)} · ${value} ${pluralize(value, 'действие', 'действия', 'действий')}" role="presentation"></span></div><span class="chart-label">${escapeHtml(label)}</span></div>`).join('');
  // Content-Security-Policy on the server only allows style-src 'self', which blocks
  // inline style="..." attributes. Setting el.style.height from script is allowed
  // (it's not parsed as an inline attribute by CSP), so we apply heights here instead.
  $$('.chart-bar', chart).forEach(bar => {
    bar.style.height = `${bar.dataset.height}%`;
  });
  chart.setAttribute('aria-label', `График: ${filtered.length} ${pluralize(filtered.length, 'действие', 'действия', 'действий')} за выбранный период`);
  $('#chart-total').textContent = filtered.length.toLocaleString('ru-RU');
  const periodLabels = { '24h': 'за последние 24 часа', '7d': 'за последние 7 дней', '30d': 'за последние 30 дней', all: 'за всё время' };
  $('#chart-subtitle').textContent = `Действия с файлами ${periodLabels[state.period]}`;
  $('#summary-period').textContent = periodLabels[state.period].replace('за ', 'За ');
}

function pluralize(count, one, few, many) {
  const value = Math.abs(count) % 100;
  const last = value % 10;
  if (value > 10 && value < 20) return many;
  if (last > 1 && last < 5) return few;
  return last === 1 ? one : many;
}

function renderMetrics() {
  const periodEvents = state.events.filter(event => inPeriod(event));
  const users = new Set(periodEvents.map(event => `${event.domain || ''}\\${event.user || ''}`));
  const files = new Set(periodEvents.map(event => String(event.path || '').toLocaleLowerCase('ru-RU')));
  $('#metric-writes').textContent = periodEvents.filter(event => event.operation === 'Запись').length.toLocaleString('ru-RU');
  $('#metric-deletes').textContent = periodEvents.filter(event => event.operation === 'Удаление').length.toLocaleString('ru-RU');
  $('#metric-users').textContent = users.size.toLocaleString('ru-RU');
  $('#metric-files').textContent = files.size.toLocaleString('ru-RU');
}

function renderMeta() {
  const collector = state.status?.collector || {};
  const running = Boolean(state.connected && collector.state === 'running');
  const stale = Boolean(state.connected && collector.state === 'stale');
  const host = collector.computer || state.status?.computer || '';
  const paths = Array.isArray(collector.paths) ? collector.paths : [];
  const banner = $('#demo-banner');
  const bannerDismissed = sessionStorage.getItem('audit-demo-banner-dismissed') === '1';
  banner.hidden = !state.demo || bannerDismissed;

  $('#source-tag').classList.toggle('is-live', !state.demo && running);
  $('#source-tag').querySelector('span:last-child').textContent = state.demo ? 'Демо' : running ? 'Журнал Windows' : 'Нет связи';
  $('#sidebar-status-dot').classList.toggle('is-live', running);
  $('#sidebar-status-dot').classList.toggle('is-warning', stale);
  $('#server-host').textContent = host || (state.demo ? 'Демонстрационные данные' : running ? 'Сборщик активен' : 'Сборщик остановлен');

  const pill = $('#source-status-pill');
  pill.className = `status-pill ${running ? 'status-live' : stale ? 'status-stale' : 'status-idle'}`;
  pill.innerHTML = `<span aria-hidden="true"></span>${running ? 'Сбор идёт' : stale ? 'Нет обновлений' : state.demo ? 'Не настроен' : 'Остановлен'}`;
  $('#source-status-icon').classList.toggle('is-live', running);
  $('#source-status-title').textContent = running ? 'Сбор работает' : stale ? 'Нет ответа от службы сбора' : state.demo ? 'Сбор не настроен' : 'Ожидаем события';
  $('#source-status-copy').textContent = running
    ? `Получаем события файловой системы с ${host || 'сервера'}.`
    : stale
      ? 'Проверьте задачу планировщика Windows и доступ сборщика к журналу Security.'
      : 'Настройте аудит файловой системы на Windows Server, чтобы получать реальные события.';
  $('#collector-state').textContent = running ? 'Активен' : stale ? 'Нет обновлений' : state.demo ? 'Не настроен' : 'Остановлен';
  $('#collector-host').textContent = host || '—';
  $('#collector-last-check').textContent = collector.lastPoll ? dateParts(collector.lastPoll).full : '—';
  $('#log-directory').textContent = state.status?.logsDirectory || state.status?.dataDirectory || 'Будет выбрана при настройке';
  $('#source-root-count').textContent = paths.length.toLocaleString('ru-RU');
  const rootList = $('#source-roots-list');
  rootList.innerHTML = paths.length
    ? paths.map(path => `<div class="root-row"><svg viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="M2.75 5.5a1.75 1.75 0 0 1 1.75-1.75H8l1.6 1.75h5.9a1.75 1.75 0 0 1 1.75 1.75v7a1.75 1.75 0 0 1-1.75 1.75h-11A1.75 1.75 0 0 1 2.75 14.25V5.5Z" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg><code title="${escapeHtml(path)}">${escapeHtml(path)}</code></div>`).join('')
    : '<div class="source-empty"><span class="source-empty-mark" aria-hidden="true"></span><span>Папки ещё не добавлены</span></div>';

  const relative = state.updatedAt ? timeAgo(state.updatedAt) : '—';
  $('#refresh-label').textContent = state.connected ? `Обновлено ${relative}` : 'Локальный предпросмотр';
  $('#table-updated').textContent = state.connected ? 'Автообновление · 10 сек' : 'Демонстрационные данные';
  $('#all-table-updated').textContent = state.connected ? 'Автообновление · 10 сек' : 'Демонстрационные данные';
}

function timeAgo(time) {
  const elapsed = Math.max(0, Date.now() - time);
  if (elapsed < 5_000) return 'только что';
  if (elapsed < 60_000) return `${Math.floor(elapsed / 1000)} сек. назад`;
  return `${Math.floor(elapsed / 60_000)} мин. назад`;
}

function render() {
  renderMeta();
  renderMetrics();
  renderChart();
  const overviewEvents = visibleEvents({ search: $('#search-input').value, operation: $('#operation-select').value });
  const allEvents = visibleEvents({ search: $('#events-search-input').value, operation: $('#events-operation-select').value, period: $('#events-period-select').value });
  const listedCount = Math.min(overviewEvents.length, 6);
  $('#table-count').textContent = `${overviewEvents.length.toLocaleString('ru-RU')} ${pluralize(overviewEvents.length, 'действие', 'действия', 'действий')}`;
  $('#table-footer-label').textContent = overviewEvents.length ? `Показаны ${listedCount} из ${overviewEvents.length.toLocaleString('ru-RU')}` : 'Действий не найдено';
  $('#clear-search').hidden = !$('#search-input').value && $('#operation-select').value === 'all';
  $('#all-table-footer-label').textContent = allEvents.length ? `Показано ${Math.min(allEvents.length, 200).toLocaleString('ru-RU')} из ${allEvents.length.toLocaleString('ru-RU')} действий` : 'Действий не найдено';
  $('#all-clear-search').hidden = !$('#events-search-input').value && $('#events-operation-select').value === 'all' && $('#events-period-select').value === '24h';
  $('#nav-event-count').textContent = state.events.length > 99 ? '99+' : state.events.length.toLocaleString('ru-RU');
  renderTable('#events-body', '#empty-state', overviewEvents, 6, true);
  renderTable('#all-events-body', '#all-empty-state', allEvents, 200, false);
}

async function refresh() {
  if (document.hidden) return;
  const [statusResult, eventsResult] = await Promise.allSettled([
    fetch('/api/status', { cache: 'no-store' }).then(response => { if (!response.ok) throw new Error('status'); return response.json(); }),
    fetch('/api/events?limit=20000', { cache: 'no-store' }).then(response => { if (!response.ok) throw new Error('events'); return response.json(); })
  ]);
  state.connected = statusResult.status === 'fulfilled' && eventsResult.status === 'fulfilled';
  state.status = state.connected ? statusResult.value : null;
  const received = state.connected && Array.isArray(eventsResult.value.events) ? eventsResult.value.events : [];
  const collectorRunning = state.status?.collector?.state === 'running';
  const hasConfiguredPaths = Boolean(state.status?.collector?.paths?.length);
  state.demo = !state.connected || (!received.length && !collectorRunning && !hasConfiguredPaths);
  state.rawEvents = state.demo ? sampleEvents : received;
  state.events = consolidateEvents(state.rawEvents);
  state.updatedAt = Date.now();
  render();
}

function updatePeriod(period) {
  state.period = period;
  $('#period-select').value = period;
  $('#events-period-select').value = period;
  render();
}

function csvEscape(value) { return `"${String(value ?? '').replaceAll('"', '""')}"`; }

function downloadCsv(events) {
  if (!events.length) {
    showToast('Нет действий для экспорта.');
    return;
  }
  const columns = ['Время', 'Пользователь', 'Учётная запись', 'Действие', 'Файл', 'Путь', 'Процесс', 'Сервер', 'Число событий Windows', 'ID событий Windows', 'ID записей журнала'];
  const rows = events.map(event => [
    new Date(event.time).toISOString(), displayUser(event), displayAccount(event), event.operation, basename(event.path), event.path, event.process, event.computer, event.rawCount, event.eventIds.join(', '), event.recordIds.join(', ')
  ]);
  const csv = '\ufeff' + [columns, ...rows].map(row => row.map(csvEscape).join(';')).join('\r\n');
  const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = `audit-${new Date().toISOString().slice(0, 10)}.csv`;
  anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  showToast(`Экспортировано: ${events.length} ${pluralize(events.length, 'действие', 'действия', 'действий')}.`);
}

let toastTimer;
function showToast(message) {
  const toast = $('#toast');
  toast.textContent = message;
  toast.classList.add('is-visible');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('is-visible'), 3200);
}

function openConnectDialog() {
  const dialog = $('#connect-dialog');
  if (!dialog.open) dialog.showModal();
}

function setView(view) {
  state.view = view;
  $$('.view-panel').forEach(panel => {
    const active = panel.id === `${view}-view`;
    panel.classList.toggle('is-visible', active);
    panel.hidden = !active;
  });
  $$('.nav-link').forEach(button => {
    const active = button.dataset.view === view;
    button.classList.toggle('is-active', active);
    if (active) button.setAttribute('aria-current', 'page');
    else button.removeAttribute('aria-current');
  });
  const hash = `#${view}`;
  if (location.hash !== hash) history.replaceState(null, '', hash);
}

function clearFilters(scope) {
  if (scope === 'overview') {
    $('#search-input').value = '';
    $('#operation-select').value = 'all';
  } else {
    $('#events-search-input').value = '';
    $('#events-operation-select').value = 'all';
    $('#events-period-select').value = '24h';
    state.period = '24h';
    $('#period-select').value = '24h';
  }
  render();
}

$$('[data-open-connect]').forEach(button => button.addEventListener('click', openConnectDialog));
$$('[data-close-dialog]').forEach(button => button.addEventListener('click', () => $('#connect-dialog').close()));
$('#connect-dialog').addEventListener('click', event => { if (event.target === $('#connect-dialog')) $('#connect-dialog').close(); });
$$('[data-view]').forEach(button => button.addEventListener('click', () => setView(button.dataset.view)));
$$('[data-show-events]').forEach(button => button.addEventListener('click', () => setView('events')));
$('#period-select').addEventListener('change', event => updatePeriod(event.target.value));
$('#events-period-select').addEventListener('change', event => updatePeriod(event.target.value));
$('#search-input').addEventListener('input', render);
$('#operation-select').addEventListener('change', render);
$('#events-search-input').addEventListener('input', render);
$('#events-operation-select').addEventListener('change', render);
$('#clear-search').addEventListener('click', () => clearFilters('overview'));
$('#all-clear-search').addEventListener('click', () => clearFilters('events'));
$('#export-button').addEventListener('click', () => downloadCsv(visibleEvents({ search: $('#search-input').value, operation: $('#operation-select').value })));
$('#events-export-button').addEventListener('click', () => downloadCsv(visibleEvents({ search: $('#events-search-input').value, operation: $('#events-operation-select').value, period: $('#events-period-select').value })));
$('#events-refresh').addEventListener('click', refresh);
$('#demo-banner [data-dismiss-banner]').addEventListener('click', () => { sessionStorage.setItem('audit-demo-banner-dismissed', '1'); $('#demo-banner').hidden = true; });
$('#search-input').addEventListener('keydown', event => { if (event.key === 'Enter') setView('events'); });
$('#events-search-input').addEventListener('keydown', event => { if (event.key === 'Escape') { event.target.value = ''; render(); } });
document.addEventListener('keydown', event => {
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') {
    event.preventDefault();
    const field = state.view === 'events' ? $('#events-search-input') : $('#search-input');
    field.focus();
  }
});
document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });

const initialView = location.hash.slice(1);
if (['overview', 'events', 'sources'].includes(initialView)) setView(initialView);
refresh();
setInterval(refresh, 10_000);
