<script lang="ts">
  import type { SegmentCurve } from "../../curve_projection.js";
  import type { StrokeSample } from "../../stroke.js";

  // 干预曲线层：只读渲染已挂载 patch 的控制点折线；绘制模式（drawing=true）
  // 下 overlay 接管指针事件采样笔画，pointerup 经 onStroke 回调上抛
  // （绝对 tick + midi pitch 采样，抽稀/锚定在外层纯函数完成）。
  // value 直接当 midi pitch 复用琴键纵轴（v1 简化，正式版再议独立参数轴）。
  let {
    viewport,
    curves = [],
    drawing = false,
    onStroke = (_samples: StrokeSample[]) => {},
  }: {
    viewport: any;
    curves: SegmentCurve[];
    drawing?: boolean;
    onStroke?: (samples: StrokeSample[]) => void;
  } = $props();

  const COLORS = ["#f59e0b", "#38bdf8", "#a78bfa", "#34d399"];

  let strokeSamples = $state<StrokeSample[]>([]);
  let stroking = $state(false);

  function polylinePoints(curve: SegmentCurve): string {
    return curve.points
      .map((p) => `${viewport.timeToPixel(p.tick)},${viewport.pitchToPixel(p.value)}`)
      .join(" ");
  }

  let strokePolyline = $derived(
    strokeSamples
      .map((s) => `${viewport.timeToPixel(s.tick)},${viewport.pitchToPixel(s.value)}`)
      .join(" ")
  );

  function sampleAt(e: PointerEvent): StrokeSample {
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    return {
      tick: viewport.pixelToTime(e.clientX - rect.left),
      value: viewport.pixelToPitch(e.clientY - rect.top),
    };
  }

  function handlePointerDown(e: PointerEvent) {
    if (!drawing || e.button !== 0) return;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    stroking = true;
    strokeSamples = [sampleAt(e)];
  }

  function handlePointerMove(e: PointerEvent) {
    if (!stroking) return;
    strokeSamples = [...strokeSamples, sampleAt(e)];
  }

  function handlePointerUp(e: PointerEvent) {
    if (!stroking) return;
    stroking = false;
    const samples = strokeSamples;
    strokeSamples = [];
    if (samples.length >= 2) onStroke(samples);
  }
</script>

<div
  class="absolute inset-0 w-full h-full z-10 {drawing
    ? 'pointer-events-auto cursor-crosshair'
    : 'pointer-events-none'}"
  onpointerdown={handlePointerDown}
  onpointermove={handlePointerMove}
  onpointerup={handlePointerUp}
  role="presentation"
>
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
    {#if stroking && strokeSamples.length > 1}
      <polyline
        points={strokePolyline}
        fill="none"
        stroke="#34d399"
        stroke-width="2"
        stroke-dasharray="4 3"
      />
    {/if}
  </svg>
</div>
