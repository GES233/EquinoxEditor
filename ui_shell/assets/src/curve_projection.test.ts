import { describe, it, expect } from "vitest";
import { curvesForSegment } from "$lib/curve_projection";
import type { PatchData, SegmentData } from "$lib/bridge";

const segment: SegmentData = {
  id: "w0",
  track_id: "track_1",
  name: "w0",
  offset_tick: 480,
  notes: [{ id: "n1", start_tick: 0, duration_tick: 480, key: 60, lyric: "la", phoneme: null, extra: {} }],
  curves: {},
  extra: {},
};

const curvePatch: PatchData = {
  id: "Patch_1",
  channel: "curve",
  anchor: { kind: "ordinal", refs: ["n1"] },
  payload: {
    param: "pitch",
    adapter: "Elixir.Coconut.Curve.Adapter.Bezier",
    points: [
      { tick: 480, value: 62.0 },
      { tick: 720, value: 65.0 },
      { tick: 940, value: 60.0 },
    ],
  },
};

describe("curvesForSegment", () => {
  it("把 segment 区间内的曲线 patch 转为相对 tick", () => {
    const curves = curvesForSegment([curvePatch], segment);

    expect(curves).toHaveLength(1);
    expect(curves[0].patchId).toBe("Patch_1");
    expect(curves[0].param).toBe("pitch");
    expect(curves[0].points).toEqual([
      { tick: 0, value: 62.0 },
      { tick: 240, value: 65.0 },
      { tick: 460, value: 60.0 },
    ]);
  });

  it("区间外的 patch 不收录；非 curve channel 不收录", () => {
    const outOfRange: PatchData = {
      ...curvePatch,
      id: "Patch_far",
      payload: { param: "pitch", points: [{ tick: 9999, value: 60.0 }] },
    };
    const wrongChannel: PatchData = {
      ...curvePatch,
      id: "Patch_ph",
      channel: "phoneme_timing",
      payload: { deltas: [] },
    };

    expect(curvesForSegment([outOfRange], segment)).toEqual([]);
    expect(curvesForSegment([wrongChannel], segment)).toEqual([]);
  });

  it("空输入安全：无 patches / 无 segment / 空 points", () => {
    expect(curvesForSegment(undefined, segment)).toEqual([]);
    expect(curvesForSegment([curvePatch], null)).toEqual([]);
    expect(
      curvesForSegment([{ ...curvePatch, payload: { param: "pitch", points: [] } }], segment)
    ).toEqual([]);
  });
});
