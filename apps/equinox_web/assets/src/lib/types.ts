// 组件只消费 facade 的投影；精确音高字符串在非音高编辑时原样保留。
export interface Voicebank {
  id: string;
  name: string;
  mode: string | null;
  engine: string;
  digest: string;
}

export interface Note {
  id: string;
  start_tick: number;
  end_tick: number;
  pitch: number | string | null;
  lyric: string | null;
}

export interface Track {
  id: string;
  name: string | null;
  voicebank: { name: string; engine: string; digest: string } | null;
  notes: Note[];
  pins: Pin[];
}

export type PitchPoint = [number, number];
export interface Pin {
  id: string;
  channel: 'pitch' | 'duration';
  anchor: { type: string; refs: string[]; at_version: number };
  payload: unknown;
}

export interface CheckEntry {
  kind: string;
  track_id?: string;
  note_id?: string;
  note_ids?: string[];
  patch_id?: string;
  channel?: string;
  reason?: unknown;
}

export interface CheckReport {
  history_pin: number;
  status: 'ok' | 'failed';
  entries: CheckEntry[];
}

export type CheckState = 'unchecked' | 'checking' | 'ok' | 'failed' | 'error';
export interface PinToken { track_id: string; note_id: string; history_pin: number }
export interface EditResult {
  history_pin: number;
  results?: { patch_id: string; status: 'repatched' | 'degraded'; reason?: unknown }[];
}

export interface Snapshot {
  project_id: string;
  history_pin: number;
  can_undo: boolean;
  can_redo: boolean;
  tracks: Track[];
}

export type ConnectionState = 'connecting' | 'connected' | 'disconnected';

export type EditIntent =
  | { command: 'edit_note'; track_id: string; note_id: string; changes: { lyric?: string; pitch?: number } }
  | { command: 'move_note'; track_id: string; note_id: string; span: [number, number] }
  | { command: 'rebind_voicebank'; track_id: string; voicebank_id: string }
  | { command: 'mount_pitch'; track_id: string; note_id: string; points: PitchPoint[]; token: PinToken }
  | { command: 'replace_pitch'; track_id: string; patch_id: string; points: PitchPoint[] }
  | { command: 'repatch'; track_id: string; patch_ids: string[] }
  | { command: 'unmount_pitch'; track_id: string; note_id: string }
  | { command: 'undo' | 'redo' };
