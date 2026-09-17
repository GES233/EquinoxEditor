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
  | { command: 'undo' | 'redo' };
