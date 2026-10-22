export type Course = {
  id: string;
  name: string;
  accentCode: string;
  createdAt: string;
  scheduleType: string;
  scheduleDate: string;
  scheduleWeekday?: number;
  scheduleMonthDay?: number;
  scheduleTime?: string;
};
export type RecordSummary = {
  id: string;
  course_id?: string;
  title: string;
  date: string;
  duration: number;
  preview: string;
};
export type Caption = {
  review_status?: string;
  id: string;
  text: string;
  final: boolean;
  start?: number;
  utterance?: number;
};
export type LanguageRow = {
  uncertain?: boolean;
  annotation_suppressed?: boolean;
  background_candidate?: boolean;
  correction_status?: string;
  english: string;
  chinese: string;
  original: string;
  members: string[];
  status: string;
  error?: string;
};
export type Session = {
  warnings?: string[];
  presentation?: Pick<Session, 'rows' | 'live' | 'language_rows' | 'speaker_rows'>;
  summary?: { status: string; text: string; error?: string };
  revision?: {
    status: string;
    text?: string;
    revised_rows?: number;
    processed_rows?: number;
    total_rows?: number;
    failed_rows?: number;
  };
  speaker_names?: Record<string, string>;
  content_edits?: Record<string, { speaker: string; original: string; translated: string }>;
  speaker_rows?: Record<
    string,
    { label: string; speaker_id: number; role: string; role_score?: number }
  >;
  phase: string;
  error?: string;
  rows: Caption[];
  live: { stable: string; unstable: string }[];
  language_rows: Record<string, LanguageRow>;
  metrics: { captured_seconds: number; rms: number; stage?: string };
  config: { course_id?: string; course_name?: string };
};
export type Preferences = {
  background_filter?: boolean;
  course_terms?: string;
  noise_reduction: boolean;
  model: string;
  device: number | null;
  font_size: number;
  auto_scroll: boolean;
};
export type Config = {
  version?: string;
  session_token: string;
  models: { name: string; ready: boolean }[];
  devices: { id: number; name: string; default: boolean }[];
  settings: Preferences;
  translation_configured: boolean;
  revision_configured: boolean;
};
export type Library = {
  courses: Course[];
  records: RecordSummary[];
  warnings?: { message: string; code: string; record_id: string }[];
};
export type Page = 'courses' | 'course' | 'history' | 'settings' | 'recording' | 'record';
