<script lang="ts">
  import type { SegmentCurve } from "../../curve_projection.js";

  // 只读干预曲线层：patch payload 的控制点折线 + 控制点圆点。
  // value 直接当 midi pitch 复用琴键纵轴（最小切片简化，正式版再议独立参数轴）。
  let { viewport, curves = [] }: { viewport: any; curves: SegmentCurve[] } = $props();

  const COLORS = ["#f59e0b", "#38bdf8", "#a78bfa", "#34d399"];

  function polylinePoints(curve: SegmentCurve): string {
    return curve.points
      .map((p) => `${viewport.timeToPixel(p.tick)},${viewport.pitchToPixel(p.value)}`)
      .join(" ");
  }
</script>

<div class="absolute inset-0 w-full h-full pointer-events-none z-10">
  <svg class="w-full h-full overflow-visible">
    {#each curves as curve, i}
      {@const color = COLORS[i % COLORS.length]}
      <polyline
        points={polylinePoints(curve)}
        fill="none"
        stroke={color}
        stroke-width="2"
        stroke-opacity="0.85"
      />
      {#each curve.points as point}
        <circle
          cx={viewport.timeToPixel(point.tick)}
          cy={viewport.pitchToPixel(point.value)}
          r="4"
          fill={color}
          stroke="#fff"
          stroke-width="1"
        />
      {/each}
    {/each}
  </svg>
</div>
