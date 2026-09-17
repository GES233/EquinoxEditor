<script lang="ts">
  import type { Note, Track } from '../lib/types';

  let { track, historyPin, disabled, onmove }: {
    track: Track | undefined;
    historyPin: number;
    disabled: boolean;
    onmove: (note: Note, span: [number, number]) => void;
  } = $props();

  const rowHeight = 28;
  const left = 64;
  const top = 40;
  const pixelsPerTick = 0.4;
  const width = 1120;
  const pitches = Array.from({ length: 17 }, (_, i) => 72 - i);
  const names = ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'];
  let svg: SVGSVGElement;
  let drag = $state<{ note: Note; clientX: number; start: number; pointerId: number } | null>(null);

  // 权威版本或提交状态变化时取消未完成手势，不把旧预览带入新版本。
  $effect(() => { void historyPin; void disabled; drag = null; });

  function start(event: PointerEvent, note: Note) {
    if (disabled || event.button !== 0 || track?.notes.length !== 1) return;
    event.preventDefault();
    (event.currentTarget as Element).setPointerCapture(event.pointerId);
    drag = { note, clientX: event.clientX, start: note.start_tick, pointerId: event.pointerId };
  }

  function move(event: PointerEvent) {
    if (!drag || event.pointerId !== drag.pointerId) return;
    const scale = width / svg.getBoundingClientRect().width;
    const delta = (event.clientX - drag.clientX) * scale / pixelsPerTick;
    const maxStart = Math.max(0, 2400 - (drag.note.end_tick - drag.note.start_tick));
    drag.start = Math.min(maxStart, Math.max(0, Math.round((drag.note.start_tick + delta) / 120) * 120));
  }

  function finish(event: PointerEvent) {
    if (!drag || event.pointerId !== drag.pointerId) return;
    const { note, start } = drag;
    drag = null;
    if (start !== note.start_tick) onmove(note, [start, start + note.end_tick - note.start_tick]);
  }

  function key(event: KeyboardEvent, note: Note) {
    if (disabled || drag || track?.notes.length !== 1) return;
    const direction = event.key === 'ArrowLeft' ? -1 : event.key === 'ArrowRight' ? 1 : 0;
    if (!direction) return;
    event.preventDefault();
    const start = note.start_tick + direction * 120;
    if (start >= 0 && start + note.end_tick - note.start_tick <= 2400) {
      onmove(note, [start, start + note.end_tick - note.start_tick]);
    }
  }
</script>

<svelte:window onkeydown={(event) => { if (event.key === 'Escape') drag = null; }} onblur={() => { drag = null; }} />

<div class="roll-scroll">
  <svg bind:this={svg} {width} height={top + pitches.length * rowHeight} aria-label="钢琴卷帘" role="group">
    <defs>
      <pattern id="beat-grid" x={left} y={top} width={480 * pixelsPerTick} height={rowHeight} patternUnits="userSpaceOnUse">
        <path d={`M 0 0 H ${480 * pixelsPerTick} M 0 0 V ${rowHeight}`} fill="none" stroke="#dce1da" />
        <path d={`M ${120 * pixelsPerTick} 0 V ${rowHeight} M ${240 * pixelsPerTick} 0 V ${rowHeight} M ${360 * pixelsPerTick} 0 V ${rowHeight}`} stroke="#e9ece6" />
      </pattern>
    </defs>
    {#each pitches as pitch, index}
      <rect x="0" y={top + index * rowHeight} {width} height={rowHeight} fill={[1, 3, 6, 8, 10].includes(pitch % 12) ? '#eef0ea' : '#fafbf7'} />
      <text x="18" y={top + index * rowHeight + 18} class="key-label">{names[pitch % 12]}{Math.floor(pitch / 12) - 1}</text>
    {/each}
    <rect x={left} y={top} width={width - left} height={pitches.length * rowHeight} fill="url(#beat-grid)" />
    {#each Array.from({ length: 6 }, (_, i) => i) as beat}
      <text x={left + beat * 480 * pixelsPerTick + 8} y="24" class="beat-label">{beat + 1}</text>
    {/each}
    <line x1={left} x2={left} y1="0" y2="516" stroke="#cbd1c7" />
    {#each track?.notes ?? [] as note (note.id)}
      {@const tick = drag?.note.id === note.id ? drag.start : note.start_tick}
      {@const y = top + (72 - Math.max(56, Math.min(72, Number(note.pitch ?? 60)))) * rowHeight + 3}
      <g
        role="button" tabindex={disabled ? -1 : 0}
        aria-label={`音符 ${note.lyric ?? ''}，起点 ${tick} tick，音高 ${note.pitch ?? '未指定'}`}
        aria-disabled={disabled}
        class="note" class:dragging={drag?.note.id === note.id}
        onpointerdown={(event) => start(event, note)} onpointermove={move} onpointerup={finish}
        onpointercancel={() => { drag = null; }} onlostpointercapture={() => { drag = null; }}
        onkeydown={(event) => key(event, note)}
      >
        <rect x={left + tick * pixelsPerTick} {y} width={(note.end_tick - note.start_tick) * pixelsPerTick} height={rowHeight - 6} rx="4" />
        <text x={left + tick * pixelsPerTick + 12} y={y + 15}>{note.lyric ?? '—'}</text>
      </g>
    {/each}
  </svg>
</div>
<div class="roll-caption">
  <span>{drag ? `预览起点 ${drag.start} tick · 松手提交 / Esc 取消` : '横向拖动音符 · 方向键微移 · 吸附 120 tick'}</span>
  <span>480 tick / 拍</span>
</div>

<style>
  .roll-scroll { overflow: auto; border-block: 1px solid var(--line); background: #fafbf7; }
  svg { display: block; }
  .key-label, .beat-label { fill: var(--muted); font: 11px ui-monospace, monospace; }
  .note { cursor: grab; touch-action: none; outline: none; }
  .note rect { fill: #547762; stroke: #385743; stroke-width: 1; }
  .note text { fill: white; font-size: 12px; pointer-events: none; }
  .note:focus-visible rect { stroke: #182f24; stroke-width: 3; }
  .note.dragging { cursor: grabbing; }
  .note.dragging rect { fill: #74967b; stroke-dasharray: 4 2; }
  .roll-caption { display: flex; justify-content: space-between; gap: 16px; padding: 12px 20px; color: var(--muted); font-size: 11px; }
</style>
