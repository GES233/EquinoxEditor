<script lang="ts">
  import { untrack } from 'svelte';
  import type { OutputExtraction } from '../lib/types';
  interface ModelPin {
    id: string;
    channel: string;
    payload: unknown;
  }
  interface PitchRow {
    frame: string;
    midi: string;
  }

  let { output, noteId, pins, disabled, busy, notice, onextract, onput, onrepatch, onremove }: {
    output: OutputExtraction | null;
    noteId: string;
    pins: ModelPin[];
    disabled: boolean;
    busy: boolean;
    notice: string;
    onextract: () => void;
    onput: (channel: 'pitch' | 'duration', values: number[] | [number, number][], digest: string) => void;
    onrepatch: (patchId: string) => void;
    onremove: (channel: 'pitch' | 'duration') => void;
  } = $props();

  const MAX_POINTS = 64;
  const W = 260;
  const H = 90;
  const PAD = 6;

  const region = $derived(output?.regions[noteId]);
  const regionFrames = $derived(region?.pitch ? region.pitch.end_frame - region.pitch.start_frame : 0);

  function isV1(pin: ModelPin | undefined): boolean {
    return !!pin && (pin.payload as { schema?: string } | null)?.schema === 'model_output_v1';
  }
  function payloadValues(pin: ModelPin | undefined): unknown {
    return pin ? (pin.payload as { values?: unknown } | null)?.values : undefined;
  }

  const pitchPin = $derived(pins.find((p) => p.channel === 'pitch'));
  const durPin = $derived(pins.find((p) => p.channel === 'duration'));
  const pitchPinV1 = $derived(isV1(pitchPin));
  const durPinV1 = $derived(isV1(durPin));
  // 旧版（非 model_output_v1）pin 不提供沿用/替换，只提示去原编辑器移除。
  const legacyPitch = $derived(!!pitchPin && !pitchPinV1);
  const legacyDur = $derived(!!durPin && !durPinV1);

  // 表单基线：提取输出或 pin 变化时重算；本地已改动则保留草稿不被覆盖。
  const durDraft = $derived.by((): number[] => {
    const stored = payloadValues(durPin);
    if (durPinV1 && Array.isArray(stored)) {
      return (stored as unknown[]).map((v) => Math.max(0, Math.round(Number(v) || 0)));
    }
    const d = region?.duration;
    if (!d) return [];
    return d.segments.map((seg, i) => Math.max(0, Math.round(d.values[i] ?? seg.end - seg.start)));
  });
  const pitchDraft = $derived.by((): [number, number][] => {
    const stored = payloadValues(pitchPin);
    if (pitchPinV1 && Array.isArray(stored)) {
      return (stored as unknown[])
        .map((p) => (Array.isArray(p) ? [Number(p[0]), Number(p[1])] : null))
        .filter((p): p is [number, number] => !!p && Number.isFinite(p[0]) && Number.isFinite(p[1]));
    }
    const v = region?.pitch?.values ?? [];
    if (v.length === 0) return [];
    if (v.length === 1) return [[0, v[0]]];
    return [[0, v[0]], [regionFrames - 1, v[v.length - 1]]];
  });

  let durRows = $state<string[]>([]);
  let pitchRows = $state<PitchRow[]>([]);
  // 新提取明确重建草稿；本地输入不成为 effect 的依赖。
  $effect(() => {
    output; noteId;
    const d = durDraft;
    const p = pitchDraft;
    untrack(() => {
      durRows = d.map(String);
      pitchRows = p.map(([f, m]) => ({ frame: String(f), midi: String(m) }));
      endDrag();
    });
  });

  function parsePitchRow(row: PitchRow | undefined): [number, number] | null {
    if (!row) return null;
    const f = row.frame.trim();
    const m = row.midi.trim();
    if (f === '' || m === '') return null;
    const frame = Number(f);
    const midi = Number(m);
    if (!Number.isFinite(frame) || !Number.isFinite(midi)) return null;
    return [frame, midi];
  }

  // ---- 音素时长校验 ----
  const durParsed = $derived(durRows.map((s) => {
    const t = s.trim();
    if (t === '') return null;
    const n = Number(t);
    return Number.isInteger(n) && n >= 0 ? n : null;
  }));
  const durTotal = $derived(durParsed.reduce<number>((a, v) => a + (v ?? 0), 0));
  const durBudget = $derived(region?.duration?.values.reduce((a, b) => a + b, 0) ?? 0);
  const durValid = $derived(durParsed.every((v) => v !== null));
  const durOk = $derived(durValid && durTotal > 0 && durTotal === durBudget && durRows.length === region?.duration?.values.length);
  const canApplyDur = $derived(
    !disabled && !busy && !!region?.duration && !region.duration.blocked && !legacyDur && durOk
  );

  // ---- 音高点列校验 ----
  const pitchParsed = $derived(pitchRows.map(parsePitchRow));
  const pitchValid = $derived(
    pitchParsed.every((p) => p !== null && Number.isInteger(p[0]) && p[0] >= 0 && p[0] < regionFrames && p[1] >= 0 && p[1] <= 127)
  );
  const pitchDup = $derived.by(() => {
    const frames = pitchParsed.filter((p): p is [number, number] => p !== null).map((p) => p[0]);
    return new Set(frames).size !== frames.length;
  });
  const pitchSorted = $derived(
    pitchParsed.filter((p): p is [number, number] => p !== null).slice().sort((a, b) => a[0] - b[0])
  );
  const dragBlocked = $derived(disabled || busy || legacyPitch || !region?.pitch || !!region.pitch.blocked);
  const canApplyPitch = $derived(
    !disabled && !busy && !!region?.pitch && !region.pitch.blocked && !legacyPitch &&
    pitchValid && !pitchDup && pitchRows.length >= 1 && pitchRows.length <= MAX_POINTS
  );

  function applyDuration() {
    const d = region?.duration;
    if (!d || !canApplyDur) return;
    onput('duration', durParsed as number[], d.digest);
  }
  function applyPitch() {
    const p = region?.pitch;
    if (!p || !canApplyPitch) return;
    onput('pitch', pitchSorted, p.digest);
  }

  // ---- SVG 拖动 ----
  let dragIndex = $state<number | null>(null);
  let dragBackup = $state<PitchRow | null>(null);
  const midiRange = $derived.by(() => {
    const values = [...(region?.pitch?.values ?? []), ...pitchDraft.map((p) => p[1])];
    const low = values.reduce((a, b) => Math.min(a, b), 60);
    const high = values.reduce((a, b) => Math.max(a, b), 60);
    return [Math.max(0, Math.floor(low) - 2), Math.min(127, Math.ceil(high) + 2)];
  });

  function toX(frame: number): number {
    return PAD + (frame / Math.max(1, regionFrames - 1)) * (W - 2 * PAD);
  }
  function toY(midi: number): number {
    return H - PAD - ((midi - midiRange[0]) / (midiRange[1] - midiRange[0])) * (H - 2 * PAD);
  }
  function clampFrame(x: number): number {
    const f = Math.round(((x - PAD) / (W - 2 * PAD)) * Math.max(1, regionFrames - 1));
    return Math.min(regionFrames - 1, Math.max(0, f));
  }
  function clampMidi(y: number): number {
    const m = midiRange[0] + ((H - PAD - y) / (H - 2 * PAD)) * (midiRange[1] - midiRange[0]);
    return Math.min(127, Math.max(0, Math.round(m * 100) / 100));
  }

  const curvePoints = $derived.by(() => {
    const v = region?.pitch?.values ?? [];
    if (v.length === 0 || regionFrames <= 1) return '';
    const stride = Math.max(1, Math.ceil(v.length / 240));
    const pts: string[] = [];
    for (let i = 0; i < v.length; i += stride) pts.push(`${toX(i).toFixed(1)},${toY(v[i]).toFixed(1)}`);
    return pts.join(' ');
  });

  function onPointDown(index: number, event: PointerEvent) {
    if (dragBlocked) return;
    event.preventDefault();
    dragIndex = index;
    dragBackup = { ...pitchRows[index] };
    (event.currentTarget as SVGCircleElement).ownerSVGElement?.setPointerCapture(event.pointerId);
  }
  function onSvgMove(event: PointerEvent) {
    if (dragIndex === null || dragBlocked) return;
    const rect = (event.currentTarget as SVGSVGElement).getBoundingClientRect();
    const x = ((event.clientX - rect.left) / rect.width) * W;
    const y = ((event.clientY - rect.top) / rect.height) * H;
    pitchRows[dragIndex] = { frame: String(clampFrame(x)), midi: String(clampMidi(y)) };
  }
  function endDrag() {
    dragIndex = null;
    dragBackup = null;
  }
  function onSvgKey(event: KeyboardEvent) {
    if (event.key === 'Escape' && dragIndex !== null && dragBackup) {
      pitchRows[dragIndex] = { ...dragBackup };
      endDrag();
    }
  }

  function addPoint() {
    if (pitchRows.length >= MAX_POINTS || regionFrames <= pitchRows.length) return;
    const used = new Set(pitchParsed.filter((p): p is [number, number] => p !== null).map((p) => p[0]));
    let frame = 0;
    while (used.has(frame) && frame < regionFrames - 1) frame++;
    const last = parsePitchRow(pitchRows[pitchRows.length - 1]);
    pitchRows.push({ frame: String(frame), midi: String(last ? last[1] : 60) });
  }
  function removePoint(index: number) {
    pitchRows.splice(index, 1);
  }

  const issues = $derived((output?.entries ?? []).filter((e) => !e.note_id || e.note_id === noteId));
  const conflictBusy = $derived(disabled || busy || !output);
</script>

<svelte:window onkeydown={onSvgKey} />

<details class="output-controls" open>
  <summary>模型输出编辑</summary>

  <div class="actions">
    <button type="button" class="primary" disabled={disabled || busy} onclick={onextract}>
      {busy ? '提取中…' : '提取当前模型输出'}
    </button>
    {#if notice}<span class="hint">{notice}</span>{/if}
  </div>

  {#if !output}
    <p class="empty">尚未提取模型输出；提取后可编辑音素时长与预测音高。</p>
  {:else if !region}
    <p class="empty">当前音符没有模型输出，请先提取。</p>
  {:else}
    {#if region.duration}
      <div class="block">
        <div class="block-head">
          <span class="eyebrow">音素时长</span>
          <span class="hint">帧预算 {durTotal} / {durBudget}</span>
        </div>
        {#if region.duration.blocked}
          <p class="warn">上游输出存在冲突，需先确认上游后才能编辑。</p>
        {/if}
        {#if legacyDur}
          <p class="warn">检测到旧版时长约束，请先在原编辑器移除旧约束后再编辑模型输出。</p>
        {/if}
        <div class="ph-bar" aria-hidden="true">
          {#each durParsed as v, i (i)}
            <span style:flex-grow={v ?? 0} title={region.duration.segments[i]?.phoneme ?? ''}></span>
          {/each}
        </div>
        <div class="rows">
          {#each durRows as text, i (i)}
            <div class="row">
              <span class="ph-label">音素 {i + 1} · {region.duration.segments[i]?.phoneme ?? '?'}</span>
              <input
                type="number"
                min="0"
                step="1"
                value={text}
                aria-label={`音素 ${i + 1} 帧长`}
                disabled={disabled || busy || region.duration.blocked || legacyDur}
                oninput={(event) => (durRows[i] = event.currentTarget.value)}
              />
            </div>
          {/each}
        </div>
        {#if !durOk}
          <p class="warn">{durValid ? `帧总和不符：当前 ${durTotal}，应保持 ${durBudget}` : '存在非法或空值的帧长'}</p>
        {/if}
        <div class="actions">
          <button type="button" class="primary" disabled={!canApplyDur} onclick={applyDuration}>应用音素时长</button>
          {#if durPinV1}
            <button type="button" disabled={disabled || busy} onclick={() => onremove('duration')}>移除音素时长</button>
          {/if}
        </div>
      </div>
    {/if}

    {#if region.pitch}
      <div class="block">
        <div class="block-head">
          <span class="eyebrow">预测音高</span>
          <span class="hint">绝对 MIDI · 区域 {regionFrames} 帧</span>
        </div>
        {#if region.pitch.blocked}
          <p class="warn">上游输出存在冲突，需先确认上游后才能编辑。</p>
        {/if}
        {#if legacyPitch}
          <p class="warn">检测到旧版音高约束，请先在原编辑器移除旧约束后再编辑模型输出。</p>
        {/if}
        <!-- svelte-ignore a11y_no_noninteractive_element_interactions, a11y_no_noninteractive_tabindex -->
        <svg
          data-testid="output-pitch-curve"
          viewBox={`0 0 ${W} ${H}`}
          role="application"
          aria-label="模型音高曲线（可拖动控制点，Esc 取消拖动）"
          tabindex={dragBlocked ? -1 : 0}
          onpointermove={onSvgMove}
          onpointerup={endDrag}
          onpointercancel={() => { if (dragIndex !== null && dragBackup) pitchRows[dragIndex] = { ...dragBackup }; endDrag(); }}
          onkeydown={onSvgKey}
        >
          <polyline points={curvePoints} class="curve" fill="none" />
          {#each pitchRows as row, i (i)}
            {@const p = parsePitchRow(row)}
            {#if p}
              <circle
                cx={toX(p[0])}
                cy={toY(p[1])}
                r="5"
                role="presentation"
                class="pt"
                class:dragging={dragIndex === i}
                onpointerdown={(event) => onPointDown(i, event)}
              />
            {/if}
          {/each}
        </svg>
        <p class="hint">灰线：当前预测 · 控制点：修改目标。横轴为区域内帧偏移，纵轴为 MIDI。</p>
        <div class="row pitch-row column-labels" aria-hidden="true"><span>区域内帧</span><span>目标 MIDI</span><span></span></div>
        <div class="rows">
          {#each pitchRows as row, i (i)}
            <div class="row pitch-row">
              <input
                type="number"
                min="0"
                max={regionFrames - 1}
                step="1"
                value={row.frame}
                aria-label={`模型音高点 ${i + 1} 帧`}
                disabled={disabled || busy || region.pitch.blocked || legacyPitch}
                oninput={(event) => (pitchRows[i].frame = event.currentTarget.value)}
              />
              <input
                type="number"
                min="0"
                max="127"
                step="1"
                value={row.midi}
                aria-label={`模型音高点 ${i + 1} MIDI`}
                disabled={disabled || busy || region.pitch.blocked || legacyPitch}
                oninput={(event) => (pitchRows[i].midi = event.currentTarget.value)}
              />
              <button
                type="button"
                aria-label={`删除模型音高点 ${i + 1}`}
                disabled={disabled || busy || region.pitch.blocked || legacyPitch}
                onclick={() => removePoint(i)}
              >删除</button>
            </div>
          {/each}
        </div>
        {#if pitchDup}
          <p class="warn">点列帧偏移不能重复</p>
        {/if}
        {#if !pitchValid && pitchRows.length > 0}
          <p class="warn">帧须为 [0, {regionFrames - 1}] 内整数，MIDI 须为 [0, 127]</p>
        {/if}
        <div class="actions">
          <button
            type="button"
            disabled={disabled || busy || region.pitch.blocked || legacyPitch || pitchRows.length >= MAX_POINTS}
            onclick={addPoint}
          >添加音高点</button>
          <button type="button" class="primary" disabled={!canApplyPitch} onclick={applyPitch}>应用模型音高</button>
          {#if pitchPinV1}
            <button type="button" disabled={disabled || busy} onclick={() => onremove('pitch')}>移除模型音高</button>
          {/if}
        </div>
      </div>
    {/if}

    {#if issues.length > 0}
      <div class="issues" data-testid="output-issues">
        {#each issues as entry, i (entry.patch_id ?? i)}
          <div class="issue">
            <p class="warn">{entry.kind === 'model' ? '模型输出未能取得；已有的上游输出仍可编辑。' : '上游输出已变化，原修改等待确认。'}</p>
            {#if entry.kind === 'model'}<code>{JSON.stringify(entry.reason)}</code>{/if}
            {#if entry.channel === 'pitch' && entry.patch_id}
              <div class="actions">
                <button
                  type="button"
                  disabled={conflictBusy || !entry.patch_id || region.pitch?.blocked}
                  onclick={() => entry.patch_id && onrepatch(entry.patch_id)}
                >沿用音高修改</button>
                <button type="button" disabled={conflictBusy} onclick={() => onremove('pitch')}>移除模型音高</button>
              </div>
            {:else if entry.channel === 'duration' && entry.patch_id}
              <div class="actions">
                <button
                  type="button"
                  disabled={conflictBusy || !entry.patch_id}
                  onclick={() => entry.patch_id && onrepatch(entry.patch_id)}
                >沿用时长修改</button>
                <button type="button" disabled={conflictBusy} onclick={() => onremove('duration')}>移除音素时长</button>
              </div>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  {/if}
</details>

<style>
  .output-controls { border-top: 1px solid var(--line); padding: 22px 24px 26px; }
  summary { cursor: pointer; text-transform: uppercase; font-size: 11px; letter-spacing: .1em; font-weight: 600; color: var(--muted); margin-bottom: 16px; }
  .block { margin-top: 18px; }
  .block-head { display: flex; gap: 24px; align-items: center; margin-bottom: 12px; }
  .hint { color: var(--muted); font-size: 11px; }
  .empty { margin: 12px 0 0; font-size: 12px; color: var(--muted); }
  .warn { margin: 10px 0 0; font-size: 12px; color: var(--warning); }
  .rows { display: grid; gap: 10px; max-width: 560px; margin-top: 10px; }
  .row { display: grid; grid-template-columns: 1fr auto; gap: 10px; align-items: center; }
  .pitch-row { grid-template-columns: 1fr 1fr auto; }
  .ph-label { font-size: 12px; color: var(--ink); }
  .ph-bar { display: flex; gap: 2px; height: 8px; border-radius: 4px; overflow: hidden; background: var(--accent-soft); max-width: 560px; }
  .ph-bar span { background: var(--accent); min-width: 0; }
  svg { display: block; width: 260px; height: 90px; border: 1px solid var(--line); border-radius: 5px; background: var(--panel); touch-action: none; margin-top: 6px; }
  .curve { stroke: var(--muted); stroke-width: 1; }
  .pt { fill: var(--panel); stroke: var(--accent); stroke-width: 2; cursor: grab; }
  .pt.dragging { fill: var(--accent); cursor: grabbing; }
  .actions { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; margin-top: 14px; }
  .issues { margin-top: 18px; border-top: 1px dashed var(--line); padding-top: 14px; display: grid; gap: 12px; }
  .issue .actions { margin-top: 8px; }
  .column-labels { max-width: 560px; margin-top: 10px; font-size: 11px; color: var(--muted); }
</style>
