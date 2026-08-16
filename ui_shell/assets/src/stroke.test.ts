import { describe, it, expect } from "vitest";
import { strokeToPoints, noteIdsInRange } from "$lib/stroke";
import type { NoteData } from "$lib/bridge";

describe("strokeToPoints", () => {
  it("取整、排序、去重（同 tick 后者覆盖）", () => {
    const points = strokeToPoints(
      [
        { tick: 100.6, value: 62 },
        { tick: 10.2, value: 60 },
        { tick: 10.4, value: 61 }, // 与上一个同 tick（取整后均为 10）
        { tick: 200, value: 65 },
      ],
      24
    );

    expect(points).toEqual([
      { tick: 10, value: 61 },
      { tick: 101, value: 62 },
      { tick: 200, value: 65 },
    ]);
  });

  it("最小间隔抽稀，末点兜底补收", () => {
    const points = strokeToPoints(
      [
        { tick: 0, value: 60 },
        { tick: 10, value: 61 }, // 间隔 < 24，抽稀
        { tick: 20, value: 62 }, // 间隔 < 24，抽稀
        { tick: 23, value: 63 }, // 仍 < 24，但它是末点 → 兜底补收
      ],
      24
    );

    expect(points).toEqual([
      { tick: 0, value: 60 },
      { tick: 23, value: 63 },
    ]);
  });

  it("空输入 / 非法采样安全", () => {
    expect(strokeToPoints([])).toEqual([]);
    expect(
      strokeToPoints([
        { tick: -5, value: 60 },
        { tick: NaN, value: 60 },
      ])
    ).toEqual([]);
  });
});

describe("noteIdsInRange", () => {
  const notes: NoteData[] = [
    { id: "n1", start_tick: 0, duration_tick: 240, key: 60, lyric: "a", phoneme: null, extra: {} },
    { id: "n2", start_tick: 240, duration_tick: 480, key: 62, lyric: "b", phoneme: null, extra: {} },
    { id: "n3", start_tick: 960, duration_tick: 240, key: 64, lyric: "c", phoneme: null, extra: {} },
  ];

  it("返回与笔画区间相交的音符（绝对 tick，含 offset 换算）", () => {
    // segment offset 0：笔画 100..300 碰 n1(0..240) 和 n2(240..720)
    expect(noteIdsInRange(notes, 0, 100, 300)).toEqual(["n1", "n2"]);
    // 只碰 n3
    expect(noteIdsInRange(notes, 0, 1000, 1100)).toEqual(["n3"]);
    // 带 offset：绝对 240..480 = 相对 0..240 → n1
    expect(noteIdsInRange(notes, 240, 240, 480)).toEqual(["n1"]);
  });

  it("边界采用半开区间：贴边不算相交；无相交返回空", () => {
    // 笔画 720..960：n2 终点 720 贴边（end > from 不成立），n3 起点 960 贴边（start < to 不成立）
    expect(noteIdsInRange(notes, 0, 720, 960)).toEqual([]);
    // 反向笔画（从右往左画）自动归一
    expect(noteIdsInRange(notes, 0, 300, 100)).toEqual(["n1", "n2"]);
  });
});
