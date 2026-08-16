// Grid 吸附的纯函数（可单测）。enable 只作用于开启期间新建/修改的音符，
// 不回溯量化既有音符；关闭时仍取整——float tick 不允许进后端（tamale 精确性纪律）。

export interface GridOption {
  label: string;
  tick: number;
}

// tpqn = 480：1/4 = 480，1/8 = 240，1/16 = 120，1/32 = 60
export const GRID_OPTIONS: GridOption[] = [
  { label: "1/4", tick: 480 },
  { label: "1/8", tick: 240 },
  { label: "1/16", tick: 120 },
  { label: "1/32", tick: 60 },
];

export const DEFAULT_QUANTUM = 240;

// tick 吸附到 quantum 的最近倍数（取整）；enabled=false 时仅取整
export function snapTick(tick: number, quantum: number, enabled: boolean): number {
  if (!Number.isFinite(tick)) return 0;
  if (!enabled || quantum <= 0) return Math.max(0, Math.round(tick));
  return Math.max(0, Math.round(tick / quantum) * quantum);
}
