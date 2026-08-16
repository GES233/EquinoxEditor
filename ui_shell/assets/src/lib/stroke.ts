// 手绘笔画 → 曲线 patch 控制点的纯函数投影（可单测，无 Svelte 依赖）。
// 注：正式的 Douglas-Peucker 笔画简化是 domain 延期项（ADR-003）；
// 此处用「取整 + 最小 tick 间隔抽稀」的最小近似，足够 demo 链路真实跑通。

import type { NoteData } from "$lib/bridge";

export interface StrokeSample {
  tick: number; // 绝对 tick（采样时可为 float）
  value: number; // v1 为 midi pitch（float 合法，payload 不进 digest）
}

// 笔画采样 → 控制点：tick 取整、按 tick 排序去重、强制严格升序、
// 相邻点最小间隔 minTickGap 抽稀（首点必收，末点尽量收）。
export function strokeToPoints(
  samples: StrokeSample[],
  minTickGap = 24
): { tick: number; value: number }[] {
  const sorted = samples
    .filter((s) => Number.isFinite(s.tick) && Number.isFinite(s.value) && s.tick >= 0)
    .map((s) => ({ tick: Math.round(s.tick), value: s.value }))
    .sort((a, b) => a.tick - b.tick);

  if (sorted.length === 0) return [];

  const points: { tick: number; value: number }[] = [sorted[0]];

  for (const sample of sorted.slice(1)) {
    const last = points[points.length - 1];
    if (sample.tick === last.tick) {
      // 同 tick 采样合并：取后者值（笔画后到的覆盖）
      last.value = sample.value;
    } else if (sample.tick - last.tick >= minTickGap) {
      points.push(sample);
    }
  }

  // 末点兜底：最后一笔采样若被抽稀吞掉且与末点不同 tick，补收保持笔画右端形状
  const lastSample = sorted[sorted.length - 1];
  const lastPoint = points[points.length - 1];
  if (lastSample.tick > lastPoint.tick) {
    points.push(lastSample);
  }

  return points;
}

// 与笔画区间 [fromTick, toTick]（绝对 tick）相交的音符 id（锚定对象）；
// 无相交 → 空列表（调用方应拒绝采纳——Ordinal 锚要求 refs 非空）。
export function noteIdsInRange(
  notes: NoteData[],
  offsetTick: number,
  fromTick: number,
  toTick: number
): string[] {
  const from = Math.min(fromTick, toTick);
  const to = Math.max(fromTick, toTick);

  return notes
    .filter((note) => {
      const start = offsetTick + note.start_tick;
      const end = start + note.duration_tick;
      return start < to && end > from;
    })
    .map((note) => note.id);
}
