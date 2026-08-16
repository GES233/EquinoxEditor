import { describe, it, expect } from "vitest";
import { snapTick, GRID_OPTIONS, DEFAULT_QUANTUM } from "$lib/grid";

describe("snapTick", () => {
  it("开启时吸附到 quantum 最近倍数", () => {
    expect(snapTick(0, 240, true)).toBe(0);
    expect(snapTick(100, 240, true)).toBe(0);
    expect(snapTick(120, 240, true)).toBe(240); // 半程进位
    expect(snapTick(359, 240, true)).toBe(240); // 359/240 ≈ 1.50 以下
    expect(snapTick(360, 240, true)).toBe(480); // 360/240 = 1.5 进位
    expect(snapTick(480, 240, true)).toBe(480);
  });

  it("关闭时仅取整（float 不进后端）", () => {
    expect(snapTick(100.4, 240, false)).toBe(100);
    expect(snapTick(100.6, 240, false)).toBe(101);
  });

  it("负值与非法输入钳到 0；quantum 非法时退化为取整", () => {
    expect(snapTick(-50, 240, true)).toBe(0);
    expect(snapTick(NaN, 240, true)).toBe(0);
    expect(snapTick(100.6, 0, true)).toBe(101);
  });

  it("GRID_OPTIONS 基于 tpqn=480 且缺省为 1/8", () => {
    expect(GRID_OPTIONS.map((o) => o.tick)).toEqual([480, 240, 120, 60]);
    expect(DEFAULT_QUANTUM).toBe(240);
  });
});
