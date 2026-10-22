import { useEffect, useRef, useState } from 'react';
import {
  BookOpen,
  ArrowLeft,
  Clock3,
  Plus,
  Settings,
  Search,
  Mic,
  Pause,
  Play,
  Square,
  PanelTop,
  Download,
  Check,
  ChevronRight,
  X,
  AudioLines,
} from 'lucide-react';
import './App.css';
import { ApiError, fetchJson, fetchBlob, retryDelay } from './apiClient';
import type { Course, RecordSummary, Session, Preferences, Config, Library, Page } from './types';
import { SubtitleOverlay } from './SubtitleOverlay';
import { sanitizeCaption, stripAnnotations } from './captionText';
import { MarkdownText } from './MarkdownText';
import { markdownToPlainText } from './markdown';

const duration = (seconds = 0) =>
  `${Math.floor(seconds / 3600)}:${Math.floor((seconds / 60) % 60)
    .toString()
    .padStart(2, '0')}:${Math.floor(seconds % 60)
    .toString()
    .padStart(2, '0')}`;
const dateLabel = (value: string) => {
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? '未设置日期'
    : date.toLocaleString('zh-CN', {
        month: 'long',
        day: 'numeric',
        hour: '2-digit',
        minute: '2-digit',
      });
};
const accentLabel = (value?: string) =>
  value === 'en-US' ? '英语（美国）' : value === 'en-GB' ? '英语（英国）' : '英语 · 自动';
const repeatLabels: Record<string, string> = {
  single: '单次',
  daily: '每日',
  weekly: '每周',
  monthly: '每月',
};
const weekdays = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
const scheduleLabel = (course: Course) =>
  course.scheduleType === 'weekly' && course.scheduleWeekday !== undefined
    ? `每周${weekdays[course.scheduleWeekday]} · ${course.scheduleTime || '未设置时间'}`
    : course.scheduleType === 'monthly' && course.scheduleMonthDay
      ? `每月${course.scheduleMonthDay}号 · ${course.scheduleTime || '未设置时间'}`
      : course.scheduleType === 'daily' && course.scheduleTime
        ? `每日 · ${course.scheduleTime}`
        : (repeatLabels[course.scheduleType] || '单次') +
          ' · ' +
          (course.scheduleDate ? dateLabel(course.scheduleDate) : dateLabel(course.createdAt));
const phaseLabel: Record<string, string> = {
  idle: '准备就绪',
  loading: '正在加载语音模型…',
  recording: '正在录音',
  paused: '录音已暂停',
  stopping: '正在保存与收尾…',
  done: '录音已保存',
  error: '录音异常',
};

function pairedRows(session: Session | null, filterBackground = true) {
  if (!session) return [];
  const language = session.language_rows || {},
    hidden = new Set(Object.values(language).flatMap((r) => r.members?.slice(1) || []));
  const background = new Set(
    Object.values(language)
      .filter(
        (r) =>
          filterBackground &&
          r.background_candidate &&
          !r.members?.some((id) => {
            const row = session.rows.find((x) => x.id === id);
            const speaker = session.speaker_rows?.[String(row?.utterance)];
            return speaker?.role === 'teacher' && (speaker.role_score ?? 0) >= 0.93;
          }),
      )
      .flatMap((r) => r.members || []),
  );
  return session.rows
    .filter(
      (r) =>
        !hidden.has(r.id) &&
        !background.has(r.id) &&
        (!language[r.id]?.annotation_suppressed || !!session.content_edits?.[r.id]?.original),
    )
    .map((row) => ({
      id: row.id,
      speaker: session.speaker_rows?.[String(row.utterance)]?.label ?? '说话人',
      original: language[row.id]?.english || row.text,
      translated: language[row.id]?.chinese || '',
      ...session.content_edits?.[row.id],
      ...(session.speaker_rows?.[String(row.utterance)]?.speaker_id != null &&
      session.speaker_names?.[String(session.speaker_rows[String(row.utterance)].speaker_id)]
        ? {
            speaker:
              session.speaker_names[String(session.speaker_rows[String(row.utterance)].speaker_id)],
          }
        : {}),
      pending: language[row.id]?.uncertain
        ? '识别待确认'
        : language[row.id]?.status === 'error'
          ? '翻译暂不可用'
          : language[row.id]?.status === 'queued'
            ? '等待翻译'
            : language[row.id]?.status === 'grammar'
              ? '自动校对中'
              : language[row.id]?.status === 'translating'
                ? '翻译中…'
                : undefined,
    }))
    .map(sanitizeCaption)
    .filter((row): row is NonNullable<typeof row> => row !== null);
}
function App() {
  const [contentDraft, setContentDraft] = useState<{
    rows: { id: string; original: string; translated: string }[];
    speaker_names: Record<string, string>;
  } | null>(null);
  const [renameRecordId, setRenameRecordId] = useState<string | null>(null);
  const [newWeekday, setNewWeekday] = useState(1),
    [newMonthDay, setNewMonthDay] = useState(1),
    [newTime, setNewTime] = useState('09:00');
  const [editingCourse, setEditingCourse] = useState(false),
    [deleteCourseOpen, setDeleteCourseOpen] = useState(false);
  const [page, setPage] = useState<Page>('courses'),
    [course, setCourse] = useState<Course | null>(null),
    [library, setLibrary] = useState<Library>({ courses: [], records: [] }),
    [config, setConfig] = useState<Config | null>(null),
    [prefs, setPrefs] = useState<Preferences>({
      noise_reduction: true,
      model: 'small',
      device: null,
      font_size: 15,
      auto_scroll: true,
    }),
    [session, setSession] = useState<Session | null>(null),
    [record, setRecord] = useState<Session | null>(null),
    [recordTitle, setRecordTitle] = useState(''),
    [showNew, setShowNew] = useState(false),
    [newName, setNewName] = useState(''),
    [newAccent, setNewAccent] = useState('auto'),
    [newDate, setNewDate] = useState(''),
    [newRepeat, setNewRepeat] = useState('single'),
    [downloads, setDownloads] = useState<
      Record<string, { status: string; progress: number; error?: string }>
    >({}),
    [search, setSearch] = useState(''),
    [notice, setNotice] = useState(''),
    [busy, setBusy] = useState(false),
    [apiKey, setApiKey] = useState(''),
    [apiMessage, setApiMessage] = useState(''),
    [revisionKey, setRevisionKey] = useState(''),
    [revisionMessage, setRevisionMessage] = useState(''),
    [returnPage, setReturnPage] = useState<Page>('history'),
    [exportMenu, setExportMenu] = useState(false),
    [renameOpen, setRenameOpen] = useState(false),
    [renameTitle, setRenameTitle] = useState(''),
    [contentTab, setContentTab] = useState<'summary' | 'transcript'>('transcript');
  const [isInitialized, setIsInitialized] = useState(false);
  const [connection, setConnection] = useState<'connecting' | 'connected' | 'reconnecting'>(
    'connecting',
  );
  const [actionError, setActionError] = useState<ApiError | null>(null);
  const actionLock = useRef(false);
  const editor = useRef<HTMLDivElement>(null);
  const feed = useRef<HTMLDivElement>(null),
    followLatest = useRef(true),
    summaryDone = useRef<string | undefined>(undefined);
  const active = ['loading', 'recording', 'paused', 'stopping'].includes(session?.phase || '');
  const refreshLibrary = async () => {
    setLibrary(await fetchJson<Library>('/api/library'));
  };
  useEffect(() => {
    let disposed = false,
      initialized = false,
      failures = 0,
      previous = '';
    let knownCourses: Course[] = [];
    let timer: ReturnType<typeof setTimeout>, modelTimer: ReturnType<typeof setTimeout>;
    const controller = new AbortController();
    const options = { signal: controller.signal, timeoutMs: 5_000 };
    const poll = async () => {
      try {
        if (!initialized) {
          const value = await fetchJson<Config>('/api/config', { ...options, timeoutMs: 15_000 });
          const libraryValue = await fetchJson<Library>('/api/library', options);
          if (disposed) return;
          setConfig(value);
          setPrefs({ ...value.settings, noise_reduction: value.settings.noise_reduction ?? true });
          setLibrary(libraryValue);
          knownCourses = libraryValue.courses;
          setIsInitialized(true);
          initialized = true;
        }
        const value = await fetchJson<Session>('/api/state', options);
        if (disposed) return;
        failures = 0;
        setConnection('connected');
        setSession(value);
        if (
          value.config.course_id &&
          ['loading', 'recording', 'paused', 'stopping'].includes(value.phase)
        ) {
          const selected = knownCourses.find((item) => item.id === value.config.course_id);
          if (selected) setCourse(selected);
        }
        if (!previous && ['loading', 'recording', 'paused', 'stopping'].includes(value.phase))
          setPage('recording');
        if (previous && previous !== value.phase && value.phase === 'done') {
          const libraryValue = await fetchJson<Library>('/api/library', options);
          if (!disposed) setLibrary(libraryValue);
        }
        previous = value.phase;
      } catch (error) {
        if (disposed) return;
        failures += 1;
        initialized = false;
        setIsInitialized(false);
        setConnection('reconnecting');
        if (
          error instanceof ApiError &&
          !['UNAVAILABLE', 'DEADLINE_EXCEEDED', 'CANCELLED'].includes(error.code)
        )
          setActionError(error);
      } finally {
        if (!disposed) timer = setTimeout(poll, failures ? retryDelay(failures) : 400);
      }
    };
    const pollModels = async () => {
      try {
        const value = await fetchJson<{
          downloads: Record<string, { status: string; progress: number; error?: string }>;
          models: Config['models'];
        }>('/api/model-downloads', options);
        if (!disposed) {
          setDownloads(value.downloads);
          setConfig((current) => (current ? { ...current, models: value.models } : current));
        }
      } catch {
        // The main connection monitor owns offline feedback; avoid duplicate alerts.
      } finally {
        if (!disposed) modelTimer = setTimeout(pollModels, 5_000);
      }
    };
    void poll();
    void pollModels();
    return () => {
      disposed = true;
      controller.abort();
      clearTimeout(timer);
      clearTimeout(modelTimer);
    };
  }, []);
  const openedRecordId = (record as (Session & { id?: string }) | null)?.id;
  useEffect(() => {
    if (page !== 'record' || !openedRecordId || contentDraft) return;
    const pending =
      ['pending', 'revising', 'cancelling'].includes(record?.revision?.status || '') ||
      ['pending', 'generating'].includes(record?.summary?.status || '');
    if (!pending) return;
    let disposed = false,
      timer: ReturnType<typeof setTimeout>;
    const update = async () => {
      try {
        const next = await fetchJson<Session>('/api/records/' + openedRecordId);
        if (!disposed) setRecord(next);
      } catch (error) {
        if (!disposed)
          setActionError(
            error instanceof ApiError ? error : new ApiError('课堂记录更新失败。', 'ACTION_FAILED'),
          );
      } finally {
        if (!disposed) timer = setTimeout(update, 1000);
      }
    };
    void update();
    return () => {
      disposed = true;
      clearTimeout(timer);
    };
  }, [page, openedRecordId, record?.revision?.status, record?.summary?.status, contentDraft]);
  useEffect(() => {
    if (prefs.auto_scroll && followLatest.current && contentTab === 'transcript' && feed.current)
      feed.current.scrollTop = feed.current.scrollHeight;
  }, [session, prefs.auto_scroll, contentTab]);
  useEffect(() => {
    if (!notice) return;
    const t = setTimeout(() => setNotice(''), 6000);
    return () => clearTimeout(t);
  }, [notice]);
  async function post<T = Record<string, unknown>>(path: string, body: unknown = {}) {
    if (!config?.session_token) throw new ApiError('语音服务尚未就绪，请稍后重试。', 'NOT_READY');
    return fetchJson<T>(path, {
      method: 'POST',
      headers: { 'X-Lingo-Token': config.session_token, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      timeoutMs: 20_000,
    });
  }
  async function action(fn: () => Promise<void>) {
    if (actionLock.current) return;
    actionLock.current = true;
    setBusy(true);
    setActionError(null);
    try {
      await fn();
    } catch (error) {
      setActionError(
        error instanceof ApiError
          ? error
          : new ApiError(
              error instanceof Error ? error.message : '操作失败，请重试。',
              'ACTION_FAILED',
            ),
      );
    } finally {
      actionLock.current = false;
      setBusy(false);
    }
  }
  function navigate(next: Page, selected?: Course) {
    setExportMenu(false);
    followLatest.current = true;
    if (active && next !== 'recording') {
      setNotice('正在录音，请先结束并保存当前课堂。');
      return;
    }
    if (selected) setCourse(selected);
    setPage(next);
    setSearch('');
  }
  async function createCourse() {
    const value = await post<Course>(editingCourse ? '/api/edit-course' : '/api/courses', {
      id: editingCourse ? course?.id : undefined,
      name: newName,
      accentCode: newAccent,
      scheduleDate: newRepeat === 'single' ? newDate : '',
      scheduleType: newRepeat,
      scheduleWeekday: newWeekday,
      scheduleMonthDay: newMonthDay,
      scheduleTime: newTime,
    });
    await refreshLibrary();
    setCourse(value);
    setPage('course');
    setShowNew(false);
    setEditingCourse(false);
    setNewName('');
  }
  async function start() {
    followLatest.current = true;
    setContentTab('transcript');
    await post('/api/start', {
      ...prefs,
      course_id: course?.id,
      course_name: course?.name,
      threads: 4,
      partial_interval: 1,
      silence: 0.5,
    });
    setPage('recording');
  }
  async function summarizeRecord() {
    const id = (record as (Session & { id?: string }) | null)?.id;
    if (!id) throw Error('请先打开已保存的课堂记录');
    const updated = await post<Session>('/api/summarize-record', { id });
    setRecord(updated);
    setContentTab('summary');
  }
  async function reviseRecord() {
    const id = (record as (Session & { id?: string }) | null)?.id;
    if (!id) throw Error('请先打开已保存的课堂记录');
    const updated = await post<Session>('/api/revise-record', { id });
    setRecord(updated);
    setNotice('正在用精修模型重译本场字幕，完成后会自动更新。');
  }
  async function cancelRevision() {
    if (!openedRecordId) return;
    setRecord(await post<Session>('/api/cancel-revision', { id: openedRecordId }));
    setNotice('已请求取消；当前请求结束后停止，不再处理新条目。');
  }
  async function saveRevisionKey() {
    const value = await post<{ persisted: boolean; configured: boolean }>(
      '/api/revision-settings',
      { key: revisionKey },
    );
    setRevisionKey('');
    setRevisionMessage(
      value.persisted
        ? '已保存到系统凭据；仅在手动点击“精修译文”后调用。'
        : '当前运行已配置；系统凭据保存不可用。',
    );
  }
  async function end() {
    await post('/api/stop');
    setNotice('正在收尾并保存录音。');
  }
  async function openRecord(item: RecordSummary) {
    if (active) throw Error('请先结束并保存当前课堂');
    setExportMenu(false);
    const value = await fetchJson<Session>('/api/records/' + item.id);
    setReturnPage(page === 'course' ? 'course' : 'history');
    setRecord(value);
    setRecordTitle(item.title);
    setCourse(library.courses.find((c) => c.id === item.course_id) || null);
    setPage('record');
    setContentTab(value?.summary?.status === 'done' ? 'summary' : 'transcript');
    followLatest.current = false;
  }
  async function preference(key: keyof Preferences, value: unknown) {
    const updated = { ...prefs, [key]: value };
    setPrefs(updated);
    try {
      await post('/api/preferences', updated);
    } catch (error) {
      setPrefs(prefs);
      throw error;
    }
  }
  async function closeOverlay() {
    await post('/api/close-overlay');
    window.close();
  }
  async function showOverlay() {
    const r = await post<{ native: boolean }>('/api/subtitle-window');
    if (!r.native) window.open('/overlay', 'lingoclass-subtitles', 'width=820,height=240');
  }
  async function saveText(text: string, filename: string, format: 'txt' | 'docx' = 'txt') {
    const result = await post<{ native: boolean; saved?: boolean; error?: string; path?: string }>(
      '/api/export-text',
      { text, filename, format },
    );
    if (result.native) {
      if (result.error) throw Error(result.error);
      if (result.saved) setNotice(result.path ? '已导出到 ' + result.path : '已导出');
      else if (result.error) setNotice(result.error);
      return;
    }
    if (format === 'docx') {
      const blob = await fetchBlob('/api/export-word', {
        method: 'POST',
        headers: {
          'X-Lingo-Token': config!.session_token,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ text, filename }),
      });
      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = filename;
      link.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      return;
    }
    const url = URL.createObjectURL(
      new Blob(['\ufeff' + text], { type: 'text/plain;charset=utf-8' }),
    );
    const link = document.createElement('a');
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  function textOf(data: Session | null) {
    return (
      (data?.summary?.status === 'done'
        ? '课堂总结\n' + markdownToPlainText(data.summary.text) + '\n\n课堂记录\n'
        : '') +
      pairedRows(data, prefs.background_filter !== false)
        .map(
          (r) =>
            (r.speaker ? r.speaker + ': ' : '') +
            r.original +
            (r.translated ? '\n' + r.translated : ''),
        )
        .join('\n\n')
    );
  }
  async function exportTranscript(format: 'txt' | 'docx' = 'txt') {
    setExportMenu(false);
    if (page === 'course') {
      const items = library.records.filter((r) => r.course_id === course?.id);
      if (!items.length) throw Error('课程还没有录音');
      const texts = [];
      for (const item of items) {
        const data = await fetchJson<Session>('/api/records/' + item.id);
        texts.push(item.title + '\n' + textOf(data));
      }
      await saveText(
        texts.join('\n\n══════════\n\n'),
        (course?.name || '课程') + '.' + format,
        format,
      );
    } else {
      let data = page === 'record' ? record : session;
      const id = renameRecordId || (record as Session & { id?: string })?.id;
      if (page === 'record' && id) {
        const latest = await fetchJson<Session>('/api/records/' + id);
        data = latest;
        setRecord(latest);
      }
      if (!data) throw Error('没有可导出的内容');
      await saveText(
        textOf(data),
        (page === 'record' ? recordTitle : course?.name || '课堂录音') + '.' + format,
        format,
      );
    }
  }
  async function renameRecord() {
    const id = renameRecordId || (record as Session & { id?: string })?.id;
    if (!id) throw Error('课堂记录编号不可用');
    await post('/api/rename-record', { id, title: renameTitle });
    if (id === (record as Session & { id?: string })?.id) setRecordTitle(renameTitle.trim());
    setRenameRecordId(null);
    setRenameOpen(false);
    await refreshLibrary();
  }
  function exportControl() {
    return (
      <div className="export-control">
        <button
          aria-expanded={exportMenu}
          disabled={busy}
          onClick={() => setExportMenu(!exportMenu)}
        >
          <Download size={15} />
          导出
        </button>
        {exportMenu && (
          <div className="export-menu" role="menu">
            <button role="menuitem" onClick={() => void action(() => exportTranscript('docx'))}>
              Word 文档 <small>.docx</small>
            </button>
            <button role="menuitem" onClick={() => void action(() => exportTranscript('txt'))}>
              纯文本 <small>.txt</small>
            </button>
          </div>
        )}
      </div>
    );
  }

  useEffect(() => {
    if (contentDraft) editor.current?.focus();
  }, [contentDraft]);
  const shownSession = session?.presentation ? { ...session, ...session.presentation } : session;
  const current = page === 'record' ? record : shownSession,
    captions = pairedRows(current, prefs.background_filter !== false),
    records = library.records.filter(
      (r) =>
        (page !== 'course' || r.course_id === course?.id) &&
        (!search || (r.title + ' ' + r.preview).toLowerCase().includes(search.toLowerCase())),
    );
  useEffect(() => {
    const status = current?.summary?.status;
    if (
      status === 'done' &&
      page === 'recording' &&
      contentTab === 'transcript' &&
      summaryDone.current !== undefined &&
      summaryDone.current !== 'done'
    )
      setContentTab('summary');
    summaryDone.current = status;
  }, [current?.summary?.status, page, contentTab]);
  if (window.location.pathname === '/overlay') {
    document.documentElement.classList.add('overlay-root');
    const latest = pairedRows(shownSession).at(-1),
      liveText = (shownSession?.live || [])
        .map((part) => (part.stable + ' ' + part.unstable).trim())
        .filter(Boolean)
        .join(' ');
    const current = liveText
      ? {
          id: (latest?.id || 'start') + ':live',
          original: liveText,
          translated: '',
        }
      : latest || null;
    return <SubtitleOverlay caption={current} onClose={() => void action(closeOverlay)} />;
  }
  return (
    <div className="app-window">
      <aside className={'sidebar' + (active ? ' recording-locked' : '')}>
        <div className="sidebar-heading">
          <img src="/app-icon.png" alt="" />
          <strong>LingoClass</strong>
          <button
            title="新建课程"
            className="icon-button"
            disabled={active}
            onClick={() => {
              setEditingCourse(false);
              setNewName('');
              setNewDate('');
              setNewRepeat('single');
              setShowNew(true);
            }}
          >
            <Plus size={18} />
          </button>
        </div>
        <nav aria-label="主导航">
          <button
            className={page === 'courses' ? 'selected' : ''}
            onClick={() => navigate('courses')}
          >
            <BookOpen size={17} />
            课程
          </button>
          <button
            className={page === 'history' ? 'selected' : ''}
            onClick={() => navigate('history')}
          >
            <Clock3 size={17} />
            所有录音
          </button>
          <button
            className={page === 'settings' ? 'selected' : ''}
            onClick={() => navigate('settings')}
          >
            <Settings size={17} />
            设置
          </button>
        </nav>
        <div className="sidebar-label">我的课程</div>
        <div className="course-navigation">
          {library.courses.map((item) => (
            <button
              key={item.id}
              className={
                course?.id === item.id && ['course', 'recording'].includes(page) ? 'selected' : ''
              }
              onClick={() => navigate('course', item)}
            >
              <BookOpen size={16} />
              <span>
                <strong>{item.name}</strong>
                <small>{scheduleLabel(item)}</small>
                <small>
                  {library.records.filter((r) => r.course_id === item.id).length} 次录音
                </small>
              </span>
            </button>
          ))}
          {!library.courses.length && <p className="sidebar-empty">在课程页创建第一门课程</p>}
        </div>
      </aside>
      <main className="detail-pane">
        <header className="toolbar">
          <div className="toolbar-title">
            {(page === 'record' || page === 'recording') && (
              <button
                className="icon-button"
                aria-label="返回课堂列表"
                disabled={active}
                onClick={() =>
                  navigate(page === 'record' ? returnPage : course ? 'course' : 'courses')
                }
              >
                <ArrowLeft size={18} />
              </button>
            )}
            {page === 'courses'
              ? '课程'
              : page === 'history'
                ? '所有录音'
                : page === 'settings'
                  ? '设置'
                  : page === 'record'
                    ? recordTitle
                    : course?.name}
          </div>
          <div className="toolbar-actions">
            {(page === 'history' || page === 'course') && (
              <label className="search-field">
                <Search size={14} />
                <input
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  placeholder="搜索录音"
                />
              </label>
            )}
            {page === 'courses' && (
              <button
                className="primary"
                disabled={active}
                onClick={() => {
                  setEditingCourse(false);
                  setNewName('');
                  setNewDate('');
                  setNewRepeat('single');
                  setShowNew(true);
                }}
              >
                <Plus size={15} />
                新建课程
              </button>
            )}
            {(page === 'course' ||
              page === 'record' ||
              (page === 'recording' && captions.length > 0)) &&
              exportControl()}
            {page === 'record' && contentDraft && (
              <>
                <button onClick={() => setContentDraft(null)}>取消编辑</button>
                <button
                  className="primary"
                  disabled={busy}
                  onClick={() =>
                    void action(async () => {
                      const rows = Array.from(
                        editor.current?.querySelectorAll<HTMLElement>('[data-row-id]') || [],
                      ).map((node) => ({
                        id: node.dataset.rowId!,
                        original: (() => {
                          const paragraph = node
                            .querySelector<HTMLElement>('.original')
                            ?.cloneNode(true) as HTMLElement | undefined;
                          paragraph
                            ?.querySelectorAll('[data-speaker-id]')
                            .forEach((label) => label.remove());
                          return paragraph?.textContent?.trim() || '';
                        })(),
                        translated:
                          node.querySelector<HTMLElement>('[data-translated]')?.innerText.trim() ||
                          '',
                      }));
                      if (rows.length !== contentDraft.rows.length)
                        throw Error('请保留段落结构；可直接修改原文、译文和姓名');
                      if (rows.some((row) => !row.original)) throw Error('原文不能为空');
                      const names = { ...contentDraft.speaker_names };
                      editor.current
                        ?.querySelectorAll<HTMLElement>('[data-speaker-id]')
                        .forEach((node) => {
                          names[node.dataset.speakerId!] = node.innerText.trim();
                        });
                      const updated = await post<Session>('/api/edit-classroom', {
                        id: (record as Session & { id?: string }).id,
                        rows,
                        speaker_names: names,
                      });
                      setRecord(updated);
                      setContentDraft(null);
                      setNotice('课堂内容已保存');
                    })
                  }
                >
                  保存修改
                </button>
              </>
            )}
            {page === 'record' && !contentDraft && (
              <button
                onClick={() => {
                  const names: Record<string, string> = {};
                  Object.values(record?.speaker_rows || {}).forEach((person) => {
                    if (person.speaker_id != null)
                      names[String(person.speaker_id)] =
                        record?.speaker_names?.[String(person.speaker_id)] || person.label;
                  });
                  setContentTab('transcript');
                  setContentDraft({
                    rows: pairedRows(record).map((row) => ({
                      id: row.id,
                      original: row.original,
                      translated: row.translated,
                    })),
                    speaker_names: names,
                  });
                }}
              >
                编辑课堂内容
              </button>
            )}
            {page === 'record' && (
              <button
                onClick={() => {
                  setRenameRecordId(null);
                  setRenameTitle(recordTitle);
                  setRenameOpen(true);
                }}
              >
                改名
              </button>
            )}
            {page === 'course' && (
              <>
                <button
                  disabled={active || busy}
                  onClick={() => {
                    setEditingCourse(true);
                    setNewName(course?.name || '');
                    setNewAccent(course?.accentCode || 'auto');
                    setNewDate(course?.scheduleDate || '');
                    setNewRepeat(course?.scheduleType || 'single');
                    setNewWeekday(
                      course?.scheduleWeekday ??
                        (course?.scheduleDate ? new Date(course.scheduleDate).getDay() : 1),
                    );
                    setNewMonthDay(
                      course?.scheduleMonthDay ??
                        (course?.scheduleDate ? new Date(course.scheduleDate).getDate() : 1),
                    );
                    setNewTime(
                      course?.scheduleTime || course?.scheduleDate?.slice(11, 16) || '09:00',
                    );
                    setShowNew(true);
                  }}
                >
                  编辑课程
                </button>
                <button disabled={active || busy} onClick={() => setDeleteCourseOpen(true)}>
                  删除课程
                </button>
              </>
            )}
            {page === 'course' && (
              <button
                className="primary"
                disabled={busy || !isInitialized || connection !== 'connected'}
                onClick={() => void action(start)}
              >
                <Mic size={15} />
                开始课堂
              </button>
            )}
          </div>
        </header>
        {page === 'courses' && (
          <div className="courses-home">
            <div className="page-intro">
              <h1>我的课程</h1>
              <p>选择课程开始课堂；结束后，原文与译文会一起保存。</p>
            </div>
            {library.courses.length ? (
              <div className="course-grid">
                {library.courses.map((item) => (
                  <button
                    className="course-card"
                    key={item.id}
                    onClick={() => navigate('course', item)}
                  >
                    <span className="course-card-icon">
                      <BookOpen size={23} />
                    </span>
                    <div>
                      <h2>{item.name}</h2>
                      <p>{scheduleLabel(item)}</p>
                      <small>
                        {library.records.filter((r) => r.course_id === item.id).length} 次课堂记录 ·{' '}
                        {accentLabel(item.accentCode)}
                      </small>
                    </div>
                    <ChevronRight size={17} />
                  </button>
                ))}
              </div>
            ) : (
              <div className="overview">
                <BookOpen size={44} strokeWidth={1.2} />
                <h1>从第一门课程开始</h1>
                <p>
                  设置课程名称与上课时间，随后即可开始录音。
                  <br />
                  语法校对和翻译会在后台自动完成。
                </p>
                <button
                  className="primary"
                  onClick={() => {
                    setEditingCourse(false);
                    setNewName('');
                    setNewDate('');
                    setNewRepeat('single');
                    setShowNew(true);
                  }}
                >
                  <Plus size={15} />
                  创建课程
                </button>
              </div>
            )}
          </div>
        )}
        {(page === 'history' || page === 'course') && (
          <div className="record-list-pane">
            {page === 'course' && course && (
              <div className="course-summary">
                <h1>{course.name}</h1>
                <p>{scheduleLabel(course)}</p>
                <span>
                  <AudioLines size={14} />
                  {accentLabel(course.accentCode)} <span className="summary-divider" /> 中文
                </span>
              </div>
            )}
            {records.length ? (
              <div className="record-list">
                {records.map((item) => (
                  <div className="record-list-row" key={item.id}>
                    <button
                      className="record-item"
                      onClick={() => void action(() => openRecord(item))}
                    >
                      <div className="record-symbol">
                        <Mic size={19} />
                      </div>
                      <div>
                        <h2>{item.title}</h2>
                        <p>
                          {dateLabel(item.date)}
                          <span>·</span>
                          {duration(item.duration)}
                        </p>
                        <small>{item.preview}</small>
                      </div>
                      <ChevronRight size={16} />
                    </button>
                    <button
                      className="record-edit-button"
                      disabled={active || busy}
                      onClick={() => {
                        setRenameRecordId(item.id);
                        setRenameTitle(item.title);
                        setRenameOpen(true);
                      }}
                      aria-label={'修改课堂名称：' + item.title}
                    >
                      改名
                    </button>
                  </div>
                ))}
              </div>
            ) : (
              <div className="overview">
                <Mic size={45} strokeWidth={1.1} />
                <h1>{search ? '没有匹配的录音' : '还没有录音'}</h1>
                <p>{search ? '请换一个搜索词。' : '开始录音，创建第一份课堂记录。'}</p>
                {page === 'course' && !search && (
                  <button
                    className="primary"
                    disabled={busy || !isInitialized || connection !== 'connected'}
                    onClick={() => void action(start)}
                  >
                    <Mic size={15} />
                    开始课堂
                  </button>
                )}
              </div>
            )}
          </div>
        )}
        {(page === 'recording' || page === 'record') && (
          <div className="recording-pane">
            <div className="recording-header">
              <span>{accentLabel(course?.accentCode)} → 中文</span>
              <small>{page === 'record' ? '已保存课堂记录' : '原文 · 自动校对 · 自动翻译'}</small>
              {page === 'record' && (
                <button
                  className="record-revise-button"
                  disabled={
                    busy ||
                    record?.revision?.status === 'revising' ||
                    record?.revision?.status === 'pending' ||
                    record?.revision?.status === 'cancelling'
                  }
                  onClick={() => void action(reviseRecord)}
                >
                  {record?.revision?.status === 'revising' ||
                  record?.revision?.status === 'pending' ||
                  record?.revision?.status === 'cancelling'
                    ? '精修中…'
                    : record?.revision?.status === 'done'
                      ? '重新精修译文'
                      : '精修译文'}
                </button>
              )}
            </div>
            {page === 'record' &&
              ['pending', 'revising'].includes(record?.revision?.status || '') && (
                <button disabled={busy} onClick={() => void action(cancelRevision)}>
                  取消精修
                </button>
              )}
            <div className="content-tabs" role="tablist" aria-label="课堂内容">
              <button
                type="button"
                role="tab"
                aria-selected={contentTab === 'summary'}
                className={contentTab === 'summary' ? 'selected' : ''}
                onClick={() => setContentTab('summary')}
              >
                课堂总结
              </button>
              <button
                type="button"
                role="tab"
                aria-selected={contentTab === 'transcript'}
                className={contentTab === 'transcript' ? 'selected' : ''}
                onClick={() => setContentTab('transcript')}
              >
                转写
              </button>
            </div>
            {page === 'record' &&
              record?.revision &&
              ['pending', 'revising', 'cancelling'].includes(record.revision.status) && (
                <p className="record-revise-status">
                  {record.revision.status === 'cancelling'
                    ? '正在取消，请等待当前请求结束。'
                    : '正在精修：'}
                  已处理 {record.revision.processed_rows ?? 0} / {record.revision.total_rows ?? '…'}{' '}
                  条，更新 {record.revision.revised_rows ?? 0} 条。原译文会保留到对应条目成功完成。
                </p>
              )}
            {page === 'record' &&
              record?.revision?.status === 'done' &&
              typeof record.revision.revised_rows === 'number' && (
                <p className="record-revise-status">
                  精修完成，共更新 {record.revision.revised_rows} 行译文。
                </p>
              )}
            {page === 'record' &&
              ['error', 'cancelled'].includes(record?.revision?.status || '') && (
                <p className="record-revise-status">
                  {record?.revision?.text || '精修已中断，已保留原译文，可重试。'}
                </p>
              )}
            {page === 'record' && record?.revision?.status === 'skipped' && (
              <p className="record-revise-status">
                {record?.revision?.text || '未配置精修 Key，已保留实时译文。'}
              </p>
            )}
            <div
              className="transcript-scroll"
              ref={feed}
              onScroll={() => {
                const el = feed.current;
                if (el)
                  followLatest.current = el.scrollHeight - el.scrollTop - el.clientHeight < 70;
              }}
              style={{ fontSize: prefs.font_size }}
            >
              {contentTab === 'summary' ? (
                current?.summary ? (
                  <section className="transcript-pair classroom-summary">
                    {current.summary.status === 'done' ? (
                      <MarkdownText source={current.summary.text} />
                    ) : (
                      <p style={{ whiteSpace: 'pre-wrap' }}>
                        {current.summary.status === 'error'
                          ? current.summary.error
                          : '正在自动整理课堂要点…'}
                      </p>
                    )}
                    {page === 'record' && current.summary.status === 'error' && (
                      <button disabled={busy} onClick={() => void action(summarizeRecord)}>
                        重新生成总结
                      </button>
                    )}
                  </section>
                ) : (
                  <div className="ready-to-listen">
                    <BookOpen size={32} strokeWidth={1.3} />
                    <p>还没有课堂总结</p>
                    <small>
                      {page === 'record'
                        ? '为这次课堂整理主题、要点和作业。'
                        : '结束并保存后，这里会自动整理课堂要点。'}
                    </small>
                    {page === 'record' && (
                      <button
                        className="primary"
                        disabled={busy || !!contentDraft}
                        onClick={() => void action(summarizeRecord)}
                      >
                        生成总结
                      </button>
                    )}
                  </div>
                )
              ) : contentDraft ? (
                <div
                  className="document-editor"
                  ref={editor}
                  contentEditable
                  suppressContentEditableWarning
                  tabIndex={0}
                  role="textbox"
                  aria-label="课堂正文编辑"
                  aria-multiline="true"
                  onPaste={(event) => {
                    event.preventDefault();
                    document.execCommand(
                      'insertText',
                      false,
                      event.clipboardData.getData('text/plain'),
                    );
                  }}
                >
                  {contentDraft.rows.map((row) => {
                    const source = record?.rows.find((r) => r.id === row.id);
                    const voice = record?.speaker_rows?.[String(source?.utterance)]?.speaker_id;
                    return (
                      <section className="transcript-pair" data-row-id={row.id} key={row.id}>
                        <p className="original">
                          {voice != null && (
                            <span
                              className="speaker-label"
                              data-speaker-id={voice}
                              onBlur={(event) => {
                                const name = event.currentTarget.innerText.trim();
                                editor.current
                                  ?.querySelectorAll<HTMLElement>(
                                    '[data-speaker-id="' + voice + '"]',
                                  )
                                  .forEach((node) => {
                                    node.innerText = name;
                                  });
                              }}
                            >
                              {contentDraft.speaker_names[String(voice)]}
                            </span>
                          )}
                          <span data-original>{row.original}</span>
                        </p>
                        <p className="translated" data-translated>
                          {row.translated}
                        </p>
                      </section>
                    );
                  })}
                </div>
              ) : captions.length || (page === 'recording' && shownSession?.live?.length) ? (
                captions.map((row) => (
                  <section className="transcript-pair" key={row.id}>
                    <p className="original">
                      {row.speaker && <span className="speaker-label">{row.speaker}</span>}
                      {row.original}
                    </p>
                    {row.translated && <p className="translated">{row.translated}</p>}
                    {row.pending && !row.translated && (
                      <small className="translation-warning">{row.pending}</small>
                    )}
                  </section>
                ))
              ) : (
                <div className="ready-to-listen">
                  <Mic size={32} strokeWidth={1.3} />
                  <p>{active ? '正在聆听…' : '准备聆听'}</p>
                  <small>
                    {active
                      ? '说话后，字幕会自动显示。'
                      : '开始录音后，原文、语法校对与翻译会自动更新。'}
                  </small>
                </div>
              )}
              {contentTab === 'transcript' &&
                page === 'recording' &&
                shownSession?.live
                  ?.filter((part) => stripAnnotations(part.stable + ' ' + part.unstable))
                  .map((part, i) => (
                    <section className="transcript-pair provisional" key={'live-' + i}>
                      <p>
                        {stripAnnotations(part.stable)}{' '}
                        <span>{stripAnnotations(part.unstable)}</span>
                        <i className="live-cursor" />
                      </p>
                    </section>
                  ))}
            </div>
            {page === 'recording' ? (
              <div className="recording-controls">
                <span className="recording-status">
                  <i className={session?.phase === 'recording' ? 'recording-dot' : ''} />
                  {phaseLabel[session?.phase || 'idle']}
                </span>
                <div className="meter" title="麦克风输入电平">
                  <Mic size={14} />
                  <div>
                    <span
                      style={{
                        width: Math.min(100, (session?.metrics.rms || 0) * 500) + '%',
                      }}
                    />
                  </div>
                </div>
                <time>{duration(session?.metrics.captured_seconds)}</time>
                <div className="controls-spacer" />
                <button title="浮动字幕" onClick={() => void action(showOverlay)}>
                  <PanelTop size={15} />
                  字幕
                </button>
                {!active ? (
                  <button
                    className="primary"
                    disabled={busy || !isInitialized || connection !== 'connected'}
                    onClick={() => void action(start)}
                  >
                    <Mic size={15} />
                    {session?.phase === 'done' ? '开始下一次课堂' : '开始'}
                  </button>
                ) : (
                  <>
                    <button
                      disabled={busy || !['recording', 'paused'].includes(session?.phase || '')}
                      onClick={() =>
                        void action(async () => {
                          await post(session?.phase === 'paused' ? '/api/resume' : '/api/pause');
                        })
                      }
                    >
                      {session?.phase === 'paused' ? <Play size={14} /> : <Pause size={14} />}{' '}
                      {session?.phase === 'paused' ? '继续' : '暂停'}
                    </button>
                    <button
                      disabled={busy || session?.phase === 'stopping'}
                      onClick={() => void action(end)}
                    >
                      <Square size={12} />
                      结束并保存
                    </button>
                  </>
                )}
              </div>
            ) : (
              <div className="record-detail-footer">
                <span>原文与译文已保存 · 可在右上角改名或导出</span>
              </div>
            )}
          </div>
        )}
        {page === 'settings' && (
          <div className="settings-pane">
            <h1>设置</h1>
            <section className="settings-group">
              <h2>语音识别</h2>
              <label>
                <span>
                  识别模型<small>新录音使用此模型</small>
                </span>
                <select
                  value={prefs.model}
                  onChange={(e) => void action(() => preference('model', e.target.value))}
                >
                  {config?.models.map((item) => (
                    <option key={item.name} disabled={!item.ready} value={item.name}>
                      {item.name}
                      {item.ready ? '' : '（未下载）'}
                    </option>
                  ))}
                </select>
              </label>
              <div className="model-download-list">
                {config?.models.map((item) => (
                  <div className="model-download-row" key={item.name}>
                    <span>
                      {item.name}
                      <small>
                        {item.ready
                          ? '已安装'
                          : downloads[item.name]?.status === 'downloading'
                            ? `下载中 ${downloads[item.name].progress}%`
                            : downloads[item.name]?.error || '未安装'}
                      </small>
                    </span>
                    {!item.ready && (
                      <button
                        disabled={downloads[item.name]?.status === 'downloading'}
                        onClick={() =>
                          void action(async () => {
                            await post('/api/download-model', {
                              model: item.name,
                            });
                            setNotice('模型下载已开始');
                          })
                        }
                      >
                        {downloads[item.name]?.status === 'error' ? '重试' : '下载'}
                      </button>
                    )}
                  </div>
                ))}
              </div>
              <label>
                <span>
                  课程术语
                  <small>教师姓名、专业词汇，用逗号分隔；供后台纠错参考。</small>
                </span>
                <input
                  value={prefs.course_terms || ''}
                  placeholder="例如 Shelly Kagan, synapses"
                  onChange={(e) => setPrefs({ ...prefs, course_terms: e.target.value })}
                  onBlur={(e) => void action(() => preference('course_terms', e.target.value))}
                />
              </label>
              <label>
                <span>
                  背景降噪<small>自动减弱环境杂音；异常时可关闭回退。</small>
                </span>
                <input
                  type="checkbox"
                  checked={prefs.noise_reduction !== false}
                  onChange={(e) =>
                    void action(() => preference('noise_reduction', e.target.checked))
                  }
                />
              </label>
              <label>
                <span>
                  过滤旁聊
                  <small>自动隐藏高确定性的无关对话，保留学生课堂提问；关闭后显示全部。</small>
                </span>
                <input
                  type="checkbox"
                  checked={prefs.background_filter !== false}
                  onChange={(e) =>
                    void action(() => preference('background_filter', e.target.checked))
                  }
                />
              </label>
              <label>
                <span>麦克风</span>
                <select
                  value={prefs.device ?? ''}
                  onChange={(e) =>
                    void action(() =>
                      preference('device', e.target.value === '' ? null : Number(e.target.value)),
                    )
                  }
                >
                  <option value="">系统默认</option>
                  {config?.devices.map((item) => (
                    <option key={item.id} value={item.id}>
                      {item.name}
                    </option>
                  ))}
                </select>
              </label>
            </section>
            <section className="settings-group">
              <h2>字幕</h2>
              <label>
                <span>文字大小</span>
                <select
                  value={prefs.font_size}
                  onChange={(e) =>
                    void action(() => preference('font_size', Number(e.target.value)))
                  }
                >
                  {[13, 15, 17, 19, 21].map((n) => (
                    <option key={n} value={n}>
                      {n} pt
                    </option>
                  ))}
                </select>
              </label>
              <label>
                <span>自动滚动至最新字幕</span>
                <input
                  type="checkbox"
                  checked={prefs.auto_scroll}
                  onChange={(e) => void action(() => preference('auto_scroll', e.target.checked))}
                />
              </label>
            </section>
            <section className="settings-group">
              <h2>后台处理</h2>
              <div className="setting-row">
                <span>
                  语法校对<small>自动校对原文，保留原始识别内容。</small>
                </span>
                <span className="setting-status">
                  <Check size={14} />
                  自动
                </span>
              </div>
              <div className="setting-row">
                <span>
                  翻译
                  <small>识别稳定内容后自动翻译；未变化的内容复用结果。</small>
                </span>
                <span className="setting-status">
                  <Check size={14} />
                  自动
                </span>
              </div>
              <label>
                <span>翻译服务</span>
                <span>GLM-5.3-Flash · 智谱官方</span>
              </label>
              <label className="credential-row">
                <span>
                  API Key
                  <small>
                    {config?.translation_configured
                      ? '已配置 · 启动时自动使用'
                      : '一次配置，后续自动运行'}
                  </small>
                </span>
                <input
                  type="password"
                  value={apiKey}
                  onChange={(e) => setApiKey(e.target.value)}
                  autoComplete="off"
                  placeholder={
                    config?.translation_configured ? '已保存在系统凭据中' : '输入 API Key'
                  }
                />
              </label>
              <div className="credential-actions">
                <small>{apiMessage || '翻译文本发送至已配置服务，按用量计费。'}</small>
                <button
                  disabled={!apiKey.trim() || busy}
                  onClick={() =>
                    void action(async () => {
                      const value = await post<{ persisted: boolean; configured: boolean }>(
                        '/api/translation-settings',
                        {
                          key: apiKey,
                        },
                      );
                      setApiKey('');
                      setApiMessage(
                        value.persisted
                          ? '已保存到系统凭据，后续自动使用。'
                          : '当前运行已配置；系统凭据保存不可用。',
                      );
                      setConfig(
                        config
                          ? {
                              ...config,
                              translation_configured: value.configured,
                            }
                          : null,
                      );
                    })
                  }
                >
                  保存
                </button>
              </div>
              <label className="credential-row">
                <span>
                  课后精修 Key
                  <small>
                    MiMo-V2.6-Flash · 小米官方。手动点击“精修译文”后才调用，按用量计费。
                  </small>
                </span>
                <input
                  type="password"
                  value={revisionKey}
                  onChange={(e) => setRevisionKey(e.target.value)}
                  autoComplete="off"
                  placeholder={
                    config?.revision_configured ? '已保存在系统凭据中' : '可选 · 手动精修使用'
                  }
                />
              </label>
              <div className="credential-actions">
                <small>
                  {revisionMessage ||
                    '课后精修需手动启动；结束录音只生成总结，不自动重译整场字幕。'}
                </small>
                <button
                  disabled={!revisionKey.trim() || busy}
                  onClick={() => void action(saveRevisionKey)}
                >
                  保存
                </button>
              </div>
            </section>
          </div>
        )}
      </main>
      {connection !== 'connected' && (
        <div className="connection-banner" role="status" aria-live="polite">
          {connection === 'connecting'
            ? '正在连接语音服务…'
            : '连接中断，已有字幕保留。正在自动重连…'}
        </div>
      )}
      {library.warnings?.length ? (
        <div className="data-warning" role="status">
          {library.warnings.length} 条记录暂时无法读取，其他记录可正常使用。原文件已保留。
        </div>
      ) : null}
      {session?.warnings?.length ? (
        <div className="runtime-warning" role="alert">
          {session.warnings.join(' ')}
        </div>
      ) : null}
      {actionError && (
        <div className="action-error" role="alert">
          <span>
            {actionError.message}
            {actionError.requestId && <small>问题编号：{actionError.requestId}</small>}
          </span>
          <button onClick={() => setActionError(null)}>关闭</button>
        </div>
      )}
      {(notice || session?.error) && (
        <div className="notice" role="status">
          {notice || session?.error}
          <button title="关闭提示" className="icon-button" onClick={() => setNotice('')}>
            <X size={14} />
          </button>
        </div>
      )}

      {renameOpen && (
        <div
          className="sheet-backdrop"
          onMouseDown={(e) => {
            if (e.target === e.currentTarget) setRenameOpen(false);
          }}
        >
          <form
            className="course-sheet"
            onSubmit={(e) => {
              e.preventDefault();
              void action(renameRecord);
            }}
          >
            <header>
              <button type="button" onClick={() => setRenameOpen(false)}>
                取消
              </button>
              <h2>修改课堂名称</h2>
              <button className="primary" disabled={!renameTitle.trim() || busy}>
                保存
              </button>
            </header>
            <div className="sheet-form">
              <label>
                课堂名称
                <input
                  autoFocus
                  value={renameTitle}
                  onChange={(e) => setRenameTitle(e.target.value)}
                  maxLength={150}
                />
              </label>
            </div>
          </form>
        </div>
      )}
      {deleteCourseOpen && (
        <div className="sheet-backdrop">
          <div className="course-sheet">
            <header>
              <h2>删除课程</h2>
            </header>
            <div className="sheet-form">
              <p>删除“{course?.name}”？已有录音会保留在“所有录音”中。</p>
              <div>
                <button onClick={() => setDeleteCourseOpen(false)}>取消</button>{' '}
                <button
                  disabled={busy}
                  onClick={() =>
                    void action(async () => {
                      await post('/api/delete-course', { id: course?.id });
                      await refreshLibrary();
                      setCourse(null);
                      setPage('courses');
                      setDeleteCourseOpen(false);
                    })
                  }
                >
                  删除课程
                </button>
              </div>
            </div>
          </div>
        </div>
      )}
      {showNew && (
        <div
          className="sheet-backdrop"
          onMouseDown={(e) => {
            if (e.target === e.currentTarget) setShowNew(false);
          }}
        >
          <form
            className="course-sheet"
            onSubmit={(e) => {
              e.preventDefault();
              void action(createCourse);
            }}
          >
            <header>
              <button type="button" onClick={() => setShowNew(false)}>
                取消
              </button>
              <h2>{editingCourse ? '编辑课程' : '新建课程'}</h2>
              <button className="primary" disabled={!newName.trim() || busy}>
                {editingCourse ? '保存' : '创建'}
              </button>
            </header>
            <div className="sheet-form">
              <label>
                课程名称
                <input
                  autoFocus
                  value={newName}
                  onChange={(e) => setNewName(e.target.value)}
                  placeholder="例如：哲学 176"
                />
              </label>
              <label>
                授课语言
                <select value={newAccent} onChange={(e) => setNewAccent(e.target.value)}>
                  <option value="auto">英语 · 自动</option>
                  <option value="en-US">英语（美国）</option>
                  <option value="en-GB">英语（英国）</option>
                </select>
              </label>
              <label>
                翻译语言<span className="fixed-field">简体中文</span>
              </label>
              <label>
                重复方式
                <select value={newRepeat} onChange={(e) => setNewRepeat(e.target.value)}>
                  {Object.entries(repeatLabels).map(([value, label]) => (
                    <option key={value} value={value}>
                      {label}
                    </option>
                  ))}
                </select>
              </label>
              {newRepeat === 'single' ? (
                <label>
                  上课日期与时间
                  <input
                    type="datetime-local"
                    value={newDate}
                    onChange={(e) => setNewDate(e.target.value)}
                  />
                </label>
              ) : (
                <>
                  {newRepeat === 'weekly' && (
                    <label>
                      上课星期
                      <select
                        value={newWeekday}
                        onChange={(e) => setNewWeekday(Number(e.target.value))}
                      >
                        {[1, 2, 3, 4, 5, 6, 0].map((day) => (
                          <option key={day} value={day}>
                            {weekdays[day]}
                          </option>
                        ))}
                      </select>
                    </label>
                  )}
                  {newRepeat === 'monthly' && (
                    <label>
                      每月日期
                      <select
                        value={newMonthDay}
                        onChange={(e) => setNewMonthDay(Number(e.target.value))}
                      >
                        {Array.from({ length: 31 }, (_, i) => i + 1).map((day) => (
                          <option key={day} value={day}>
                            {day}号
                          </option>
                        ))}
                      </select>
                    </label>
                  )}
                  <label>
                    上课时间
                    <input
                      type="time"
                      required
                      value={newTime}
                      onChange={(e) => setNewTime(e.target.value)}
                    />
                  </label>
                </>
              )}
            </div>
          </form>
        </div>
      )}
    </div>
  );
}
export default App;
