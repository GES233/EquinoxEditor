<script lang="ts">
  import PianoRoll from './PianoRoll.svelte';
  import PitchControls from './PitchControls.svelte';
  import { explainReason, pitchPoints } from '../lib/pitch';
  import type { CheckReport, CheckState, Note, PitchPoint, Track } from '../lib/types';

  let { track, historyPin, disabled, report, checkState, checking, checkError, notice, onmove, oncheck, onapply, onremove, onrepatch }: {
    track: Track | undefined; historyPin: number; disabled: boolean;
    report: CheckReport | null; checkState: CheckState; checking: boolean; checkError: string; notice: string;
    onmove: (note: Note, span: [number, number]) => void;
    oncheck: () => void;
    onapply: (points: PitchPoint[], patchId?: string) => void;
    onremove: () => void;
    onrepatch: (ids: string[]) => void;
  } = $props();

  let note = $derived(track?.notes[0]);
  let pins = $derived(track?.pins.filter((pin) => pin.channel === 'pitch' && pin.anchor.refs.includes(note?.id ?? '')) ?? []);
  let stored = $derived(note ? pitchPoints(pins[0], note) : []);
  let supported = $derived(stored !== null && pins.length <= 1);
  let points = $state<PitchPoint[]>([]);
  let editing = $state(false);
  let details = $state<HTMLDivElement>();
  let dirty = $derived(JSON.stringify(points) !== JSON.stringify(stored ?? []));
  let entries = $derived(report?.entries ?? []);
  let issue = $derived(checkState === 'failed' && entries.some((entry) => entry.track_id === track?.id &&
    (entry.note_id === note?.id || entry.note_ids?.includes(note?.id ?? '') || pins.some((pin) => pin.id === entry.patch_id))));
  $effect(() => { points = (stored ?? []).map((p) => [...p] as PitchPoint); });

  function begin() {
    editing = true;
    if (!points.length && note && supported) points = [[0, Number(note.pitch ?? 60)], [Math.min(360, note.end_tick-note.start_tick-1), Number(note.pitch ?? 60)]];
  }
</script>

<div class="pitch-toolbar">
  <button disabled={disabled || !note || !supported} onclick={() => { if (editing) editing = false; else begin(); }}>{editing ? '收起音高编辑' : '编辑音高调校'}</button>
  <button disabled={disabled || checking} onclick={oncheck}>检查当前版本</button>
  <span role="status" data-testid="check-state">{checkState === 'unchecked' ? '当前版本尚未检查' : checkState === 'checking' ? '正在检查…' : checkState === 'ok' ? '当前版本检查通过' : checkState === 'failed' ? `当前版本有 ${entries.length} 项待处理` : '检查未完成'}</span>
  {#if pins.length && checkState === 'unchecked'}<span class="hint">音高调校已保存，等待检查</span>{/if}
</div>

<PianoRoll {track} {historyPin} {disabled} {onmove} {points} editingPitch={editing && supported} {dirty} {issue} ondraft={(value) => { points = value; }} onissue={() => { details?.focus(); details?.scrollIntoView({ block: 'nearest' }); }} />

{#if editing || (pins.length && !supported)}
  <PitchControls {points} duration={note ? note.end_tick-note.start_tick : 0} {disabled} {dirty} hasPin={pins.length > 0} {supported}
    ondraft={(value) => { points = value; }} onapply={() => onapply([...points].sort((a,b) => a[0]-b[0]), pins[0]?.id)}
    oncancel={() => { points = (stored ?? []).map((p) => [...p] as PitchPoint); editing = false; }} {onremove} />
{/if}

{#if notice}<p class="notice" role="status">{notice}</p>{/if}
{#if checkState === 'error'}<p class="notice" role="alert">{checkError} 可重新检查。</p>{/if}
{#if checkState === 'failed'}
  <div class="issues" bind:this={details} tabindex="-1" aria-label="调校检查结果">
    {#each entries as entry}
      <div class="entry">
        <strong>{entry.kind === 'conflict' ? '干预身份需要确认' : '检查未通过'}</strong>
        <p>{explainReason(entry.reason)}</p>
        <details><summary>查看详情</summary><code>{JSON.stringify(entry.reason)}</code></details>
      </div>
    {/each}
    {#if issue && pins.length}
      <div class="actions">
        <button {disabled} onclick={() => onrepatch(pins.map((pin) => pin.id))}>尝试沿用调校</button>
        <button disabled={disabled || !supported} onclick={begin}>重新编辑调校</button>
        <button {disabled} onclick={onremove}>移除音高调校</button>
      </div>
    {/if}
  </div>
{/if}

<style>
  .pitch-toolbar { display: flex; gap: 12px; align-items: center; padding: 0 24px 16px; flex-wrap: wrap; font-size: 12px; }
  .pitch-toolbar span, .hint { color: var(--muted); }
  .notice { margin: 12px 24px; font-size: 12px; color: var(--warning); }
  .issues { margin: 16px 24px; border-left: 3px solid var(--warning); background: #fbf5e9; padding: 14px 18px; font-size: 12px; }
  .entry { margin-bottom: 12px; } p { margin: 8px 0; } code { overflow-wrap: anywhere; }
  .actions { display: flex; gap: 8px; margin-top: 12px; }
</style>
