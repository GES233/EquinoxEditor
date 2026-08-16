<script lang="ts">
  import { Viewport } from "../../stores/viewport.svelte.js";
  import type { GridSettings } from "../../stores/grid.svelte.js";
  import { snapTick } from "../../grid.js";
  import type { SegmentCurve } from "../../curve_projection.js";
  import type { StrokeSample } from "../../stroke.js";
  import GridLayer from "./GridLayer.svelte";
  import NotesLayer from "./NotesLayer.svelte";
  import CurveLayer from "./CurveLayer.svelte";
  import TimelineRuler from "./TimelineRuler.svelte";
  import PianoKeys from "./PianoKeys.svelte";

  let {
    notes = $bindable([]),
    tempos = $bindable([{tick: 0, bpm: 120}]),
    curves = [],
    drawing = false,
    onStroke = (_samples: StrokeSample[]) => {},
    grid,
  }: {
    notes: any[];
    tempos: { tick: number; bpm: number }[];
    curves?: SegmentCurve[];
    drawing?: boolean;
    onStroke?: (samples: StrokeSample[]) => void;
    grid: GridSettings;
  } = $props();

  let viewport = new Viewport();

  // Handle zooming and panning
  function handleWheel(e: WheelEvent) {
    if (e.ctrlKey || e.metaKey) {
      // Zoom
      e.preventDefault();
      const zoomFactor = 1 - e.deltaY * 0.01;
      viewport.zoom(zoomFactor, 1, e.clientX, e.clientY);
    } else {
      // Pan
      viewport.pan(e.deltaX, e.deltaY);
    }
  }

  // Handle window resize or container size changes
  function handleResize(node: HTMLElement) {
    viewport.width = node.clientWidth;
    viewport.height = node.clientHeight;

    const resizeObserver = new ResizeObserver((entries) => {
      viewport.width = entries[0].contentRect.width;
      viewport.height = entries[0].contentRect.height;
    });

    resizeObserver.observe(node);
    return {
      destroy() {
        resizeObserver.disconnect();
      },
    };
  }

  function handleDoubleClick(e: MouseEvent) {
    // Only handle double clicks directly on the container/grid, not on notes
    if (e.target !== e.currentTarget && !(e.target as HTMLElement).classList.contains('grid-layer')) {
      return;
    }

    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    const timeTicks = viewport.pixelToTime(x);
    const pitch = Math.round(viewport.pixelToPitch(y));

    const newNote = {
      id: crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).substring(2, 15),
      start_tick: snapTick(timeTicks, grid.quantum, grid.enabled),
      length_tick: grid.enabled ? grid.quantum : 480, // Grid 开启时默认时值对齐最小单位
      pitch: pitch,
      lyric: "la",
      phonemes: {}
    };

    notes = [...notes, newNote];
  }
</script>

<div class="grid grid-cols-[60px_1fr] grid-rows-[30px_1fr] w-full h-full bg-[#fafafa] rounded border border-[#ddd] box-border overflow-hidden nodrag">
  <!-- Top Left Corner -->
  <div class="col-start-1 row-start-1 bg-slate-50 border-r border-b border-slate-300 z-20"></div>

  <!-- Timeline Ruler (Top) -->
  <div class="col-start-2 row-start-1 z-10">
    <TimelineRuler {viewport} bind:tempos />
  </div>

  <!-- Piano Keys (Left) -->
  <div class="col-start-1 row-start-2 z-10">
    <PianoKeys {viewport} />
  </div>

  <!-- Main Canvas -->
  <div
    class="col-start-2 row-start-2 relative overflow-hidden cursor-crosshair active:cursor-grabbing"
    use:handleResize
    onwheel={handleWheel}
    ondblclick={handleDoubleClick}
    role="application"
    tabindex="-1"
    aria-label="Piano Roll Canvas"
  >
    <GridLayer {viewport} {grid} />
    <NotesLayer {viewport} {grid} bind:notes />
    <CurveLayer {viewport} {curves} {drawing} {onStroke} />
  </div>
</div>
