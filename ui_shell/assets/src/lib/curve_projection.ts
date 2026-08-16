// 干预 patch → PianoRoll 可视化的纯函数投影（可单测，无 Svelte 依赖）。
// patch 投影挂在轨级（payload.points 为绝对 tick），在此按 segment 过滤并转相对 tick。

import type { PatchData, SegmentData } from "$lib/bridge";

export interface CurvePoint {
  tick: number; // segment 相对 tick
  value: number; // v1 直接当 midi pitch 用
}

export interface SegmentCurve {
  patchId: string;
  param: string;
  points: CurvePoint[];
}

// 轨级 patch 列表 → 当前 segment 可见的曲线（任一控制点落入 segment 区间即收录，
// 该 patch 的全部点转 segment 相对 tick——跨界曲线保持形状完整，渲染层自行裁剪）
export function curvesForSegment(
  patches: PatchData[] | undefined,
  segment: SegmentData | null
): SegmentCurve[] {
  if (!patches || !segment) return [];

  const offset = segment.offset_tick ?? 0;
  const segmentEnd =
    segment.notes.reduce((max, n) => Math.max(max, n.start_tick + n.duration_tick), 0) + offset;

  const curves: SegmentCurve[] = [];

  for (const patch of patches) {
    if (patch.channel !== "curve") continue;

    const payload = patch.payload;
    const points = payload?.points;
    if (!Array.isArray(points) || points.length === 0) continue;

    const inRange = points.some(
      (p) => typeof p?.tick === "number" && p.tick >= offset && p.tick <= segmentEnd
    );
    if (!inRange) continue;

    curves.push({
      patchId: patch.id,
      param: typeof payload.param === "string" ? payload.param : "unknown",
      points: points
        .filter((p) => typeof p?.tick === "number" && typeof p?.value === "number")
        .map((p) => ({ tick: p.tick - offset, value: p.value }))
    });
  }

  return curves;
}
