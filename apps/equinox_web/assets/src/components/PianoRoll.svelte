<script lang="ts">
  import type { Note, PitchPoint, Track } from '../lib/types';

  let { track, historyPin, disabled, onmove, points = [], editingPitch = false, dirty = false, issue = false, ondraft = () => {}, onissue = () => {} }: {
    track: Track | undefined;
    historyPin: number;
    disabled: boolean;
    onmove: (note: Note, span: [number, number]) => void;
    points?: PitchPoint[];
    editingPitch?: boolean;
    dirty?: boolean;
    issue?: boolean;
    ondraft?: (points: PitchPoint[]) => void;
    onissue?: () => void;
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
  let pointDrag = $state<{ index: number; original: PitchPoint[]; pointerId: number } | null>(null);

  // 权威版本或提交状态变化时取消未完成手势，不把旧预览带入新版本。
  $effect(() => { void historyPin; void disabled; void editingPitch; drag = null; pointDrag = null; });

  function cancelPoint() {
    if (pointDrag) ondraft(pointDrag.original);
    pointDrag = null;
  }

  function pointAt(event: MouseEvent): PitchPoint | null {
    const note = track?.notes[0];
    if (!note) return null;
    const rect = svg.getBoundingClientRect();
    const tick = Math.round(((event.clientX - rect.left - left) / pixelsPerTick - note.start_tick) / 30) * 30;
    const midi = Math.round((72 - (event.clientY - rect.top - top - rowHeight / 2) / rowHeight) * 100) / 100;
    return [Math.max(0, Math.min(note.end_tick - note.start_tick - 1, tick)), Math.max(56, Math.min(72, midi))];
  }

  function addPoint(event: MouseEvent) {
    if (!editingPitch || disabled || points.length >= 64) return;
    const point = pointAt(event);
    if (point && !points.some(([tick]) => tick === point[0])) ondraft([...points, point].sort((a, b) => a[0] - b[0]));
  }

  function startPoint(event: PointerEvent, index: number) {
    if (disabled || event.button !== 0) return;
    event.stopPropagation(); event.preventDefault();
    (event.currentTarget as Element).setPointerCapture(event.pointerId);
    pointDrag = { index, original: points.map((p) => [...p] as PitchPoint), pointerId: event.pointerId };
  }

  function movePoint(event: PointerEvent) {
    if (disabled || !editingPitch || !pointDrag || pointDrag.pointerId !== event.pointerId) return;
    const point = pointAt(event);
    if (point) ondraft(points.map((p, i) => i === pointDrag!.index ? point : p));
  }

  function start(event: PointerEvent, note: Note) {
    if (disabled || editingPitch || event.button !== 0 || track?.notes.length !== 1) return;
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
    if (disabled || editingPitch || drag || track?.notes.length !== 1) return;
    const direction = event.key === 'ArrowLeft' ? -1 : event.key === 'ArrowRight' ? 1 : 0;
    if (!direction) return;
    event.preventDefault();
    const start = note.start_tick + direction * 120;
    if (start >= 0 && start + note.end_tick - note.start_tick <= 2400) {
      onmove(note, [start, start + note.end_tick - note.start_tick]);
    }
  }
</script>

<svelte:window onkeydown={(event) => { if (event.key === 'Escape') { drag = null; cancelPoint(); } }} onblur={() => { drag = null; cancelPoint(); }} />

<div class="roll-scroll">
  <svg bind:this={svg} {width} height={top + pitches.length * rowHeight} aria-label="钢琴卷帘" role="group" ondblclick={addPoint}>
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
    {#if track?.notes[0]}
      {@const note = track.notes[0]}
      {@const startTick = drag?.start ?? note.start_tick}
      {#if points.length}
        <polyline data-testid="pitch-line" class="pitch-line" class:draft={dirty} class:issue
          points={[...points].sort((a,b) => a[0]-b[0]).map(([tick, midi]) => `${left + (startTick + tick) * pixelsPerTick},${top + (72-midi) * rowHeight + rowHeight/2}`).join(' ')} />
      {/if}
      {#if editingPitch}
        {#each points as [tick, midi], index}
          <circle class="pitch-point" cx={left + (startTick + tick) * pixelsPerTick} cy={top + (72-midi) * rowHeight + rowHeight/2} r="5"
            role="button" tabindex={disabled ? -1 : 0} aria-label={`拖动控制点 ${index + 1}`} aria-disabled={disabled}
            onpointerdown={(event) => startPoint(event, index)} onpointermove={movePoint}
            onpointerup={() => { pointDrag = null; }} onpointercancel={cancelPoint} onlostpointercapture={cancelPoint}
            ondblclick={(event) => event.stopPropagation()}
            onkeydown={(event) => { if (!disabled && (event.key === 'Delete' || event.key === 'Backspace')) { event.preventDefault(); ondraft(points.filter((_, i) => i !== index)); } }} />
        {/each}
      {:else}
        {#each points as [tick, midi]}
          <circle cx={left + (startTick + tick) * pixelsPerTick} cy={top + (72-midi) * rowHeight + rowHeight/2} r="3" fill={issue ? '#a56a19' : '#253fd0'} pointer-events="none" />
        {/each}
      {/if}
      {#if issue}
        <g role="button" tabindex="0" aria-label="音高调校需要处理" onclick={onissue} onkeydown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); onissue(); } }}>
          <rect x={left + startTick * pixelsPerTick} y={top + (72-Number(note.pitch ?? 60))*rowHeight - 24} width="106" height="20" rx="4" fill="#f5e5bf" />
          <text x={left + startTick * pixelsPerTick + 8} y={top + (72-Number(note.pitch ?? 60))*rowHeight - 10} fill="#81531c" font-size="11">◇ 调校需要处理</text>
        </g>
      {/if}
    {/if}
  </svg>
</div>
<div class="roll-caption">
  <span>{editingPitch ? '双击添加控制点 · 拖动调整 · Esc 取消本次拖动 · 应用后生效' : drag ? `预览起点 ${drag.start} tick · 松手提交 / Esc 取消` : '横向拖动音符 · 方向键微移 · 吸附 120 tick'}</span>
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
  .pitch-line { fill: none; stroke: #253fd0; stroke-width: 2; pointer-events: none; }
  .pitch-line.draft { stroke-dasharray: 5 3; }
  .pitch-line.issue { stroke: #a56a19; }
  .pitch-point { fill: white; stroke: #253fd0; stroke-width: 2; cursor: move; touch-action: none; }
  .pitch-point:focus-visible { stroke: #a56a19; stroke-width: 4; outline: none; }
  .roll-caption { display: flex; justify-content: space-between; gap: 16px; padding: 12px 20px; color: var(--muted); font-size: 11px; }
</style>
