<script lang="ts">
  import type { PitchPoint } from '../lib/types';
  import { untrack } from 'svelte';

  let { points, duration, disabled, dirty, hasPin, supported, ondraft, onapply, oncancel, onremove }: {
    points: PitchPoint[];
    duration: number;
    disabled: boolean;
    dirty: boolean;
    hasPin: boolean;
    supported: boolean;
    ondraft: (points: PitchPoint[]) => void;
    onapply: () => void;
    oncancel: () => void;
    onremove: () => void;
  } = $props();

  interface Row {
    offset: string;
    midi: string;
  }

  const MAX_POINTS = 64;

  // 本地字符串态只承载"正在输入"的中间值；props 变化时若与本地解析结果
  // 不一致才重同步，避免回声把用户输入到一半的文本覆盖掉。
  let rows = $state<Row[]>([]);
  $effect(() => {
    const parsed = untrack(() => rows.map((r) => parseRow(r)));
    const same =
      parsed.length === points.length &&
      parsed.every((p, i) => p !== null && p[0] === points[i][0] && p[1] === points[i][1]);
    if (!same) {
      rows = points.map((p) => ({ offset: String(p[0]), midi: String(p[1]) }));
    }
  });

  function parseRow(row: Row | undefined): PitchPoint | null {
    if (!row) return null;
    if (row.offset.trim() === '' || row.midi.trim() === '') return null;
    const offset = Number(row.offset);
    const midi = Number(row.midi);
    if (!Number.isFinite(offset) || !Number.isFinite(midi)) return null;
    return [offset, midi];
  }

  let parsed = $derived(rows.map((r) => parseRow(r)));
  let allValid = $derived(parsed.every((p) => p !== null && Number.isInteger(p[0]) && p[0] >= 0 && p[0] <= 2400 && p[1] >= 56 && p[1] <= 72));
  let duplicate = $derived.by(() => {
    const offsets = parsed.filter((p): p is PitchPoint => p !== null).map((p) => p[0]);
    return new Set(offsets).size !== offsets.length;
  });
  let outOfRange = $derived(
    parsed.filter((p): p is PitchPoint => p !== null).some((p) => p[0] >= duration)
  );
  let canApply = $derived(!disabled && supported && dirty && allValid && !duplicate && rows.length >= 1 && rows.length <= MAX_POINTS);

  // 新增点优先取 120 步长的空位；没有则退到任意未用整数偏移；再无则禁用。
  let nextOffset = $derived.by(() => {
    const used = new Set(parsed.filter((p): p is PitchPoint => p !== null).map((p) => p[0]));
    for (let o = 0; o <= duration - 1; o += 120) {
      if (!used.has(o)) return o;
    }
    for (let o = 0; o <= duration - 1; o++) {
      if (!used.has(o)) return o;
    }
    return null;
  });

  function emit() {
    if (rows.some((r) => parseRow(r) === null)) return;
    ondraft(rows.map((r) => parseRow(r)!));
  }

  function update(index: number, field: keyof Row, value: string) {
    rows[index][field] = value;
    emit();
  }

  function removePoint(index: number) {
    rows.splice(index, 1);
    emit();
  }

  function addPoint() {
    if (nextOffset === null || rows.length >= MAX_POINTS) return;
    const last = parseRow(rows[rows.length - 1]);
    rows.push({ offset: String(nextOffset), midi: String(last ? last[1] : 60) });
    emit();
  }
</script>

<div class="pitch-controls">
  <div class="pitch-heading">
    <span class="eyebrow">音高调校</span>
    <span class="hint">相对音符起点 · 绝对 MIDI</span>
  </div>

  {#if !supported}
    <p class="warn">此曲线格式暂不支持点列编辑，可以移除。</p>
  {/if}

  {#if rows.length === 0}
    <p class="empty">尚无控制点</p>
  {/if}

  <div class="rows">
    {#each rows as row, i (i)}
      <div class="row">
        <input
          type="number"
          min="0"
          max="2400"
          step="1"
          value={row.offset}
          aria-label={`控制点 ${i + 1} 偏移`}
          {disabled}
          oninput={(event) => update(i, 'offset', event.currentTarget.value)}
        />
        <input
          type="number"
          min="56"
          max="72"
          step="0.01"
          value={row.midi}
          aria-label={`控制点 ${i + 1} 音高`}
          {disabled}
          oninput={(event) => update(i, 'midi', event.currentTarget.value)}
        />
        <button type="button" aria-label={`删除控制点 ${i + 1}`} {disabled} onclick={() => removePoint(i)}>删除</button>
      </div>
    {/each}
  </div>

  {#if duplicate}
    <p class="warn">控制点偏移不能重复</p>
  {/if}
  {#if outOfRange}
    <p class="warn">有控制点超出音符范围，检查时可能需要处理。</p>
  {/if}

  <div class="actions">
    <button
      type="button"
      disabled={disabled || !supported || rows.length >= MAX_POINTS || nextOffset === null}
      onclick={addPoint}
    >添加控制点</button>
    <button type="button" class="primary" disabled={!canApply} onclick={onapply}>应用音高调校</button>
    <button type="button" {disabled} onclick={oncancel}>放弃草稿</button>
    <button type="button" disabled={!hasPin || disabled} onclick={onremove}>移除音高调校</button>
  </div>
</div>

<style>
  .pitch-controls { padding: 22px 24px 26px; border-top: 1px solid var(--line); }
  .pitch-heading { display: flex; gap: 24px; align-items: center; margin-bottom: 16px; }
  .hint { color: var(--muted); font-size: 11px; }
  .rows { display: grid; gap: 10px; max-width: 560px; }
  .row { display: grid; grid-template-columns: 1fr 1fr auto; gap: 10px; align-items: center; }
  .warn { margin: 12px 0 0; font-size: 12px; color: var(--warning); }
  .empty { margin: 0 0 4px; font-size: 12px; color: var(--muted); }
  .actions { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 18px; }
</style>
