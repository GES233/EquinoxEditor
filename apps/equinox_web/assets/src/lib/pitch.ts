import type { Note, Pin, PitchPoint } from './types';

// 只解释用于画图的坐标，不在客户端重算干预身份。
export function pitchPoints(pin: Pin | undefined, note: Note): PitchPoint[] | null {
  if (!pin) return [];
  const payload = pin.payload as { schema?: string; coordinates?: string; values?: unknown };
  const values = Array.isArray(payload) ? payload : payload?.schema === 'score_pitch_v2' && payload.coordinates === 'note_tick' ? payload.values : null;
  if (!Array.isArray(values) || !values.every((p) => Array.isArray(p) && p.length === 2 && Number.isInteger(p[0]) && typeof p[1] === 'number' && Number.isFinite(p[1]))) return null;
  return values.map(([tick, midi]) => [Array.isArray(payload) ? tick - note.start_tick : tick, midi]);
}

export function explainReason(reason: unknown): string {
  const text = JSON.stringify(reason) ?? '';
  if (/pitch_offset_out_of_range|pitch_point_outside_note/.test(text)) return '音高控制点超出当前音符范围，请重新编辑或移除调校。';
  if (/base_mismatch|digest_mismatch|conflict/.test(text)) return '调校依赖的事实已变化，需要确认是否沿用。';
  if (/missing_lyric/.test(text)) return '音符缺少歌词，暂时无法完成检查。';
  return '检查发现需要处理的问题，详情见下方。';
}
