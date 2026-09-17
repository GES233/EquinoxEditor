<script lang="ts">
  import type { Note } from '../lib/types';
  let { note, disabled, onedit }: {
    note: Note;
    disabled: boolean;
    onedit: (changes: { lyric?: string; pitch?: number }) => Promise<void>;
  } = $props();

  let lyric = $state('');
  let pitch = $state('');
  $effect(() => { lyric = note.lyric ?? ''; pitch = String(note.pitch ?? ''); });
  let changed = $derived(lyric !== (note.lyric ?? '') || pitch !== String(note.pitch ?? ''));

  async function submit(event: SubmitEvent) {
    event.preventDefault();
    if (disabled || !changed) return;
    const changes: { lyric?: string; pitch?: number } = {};
    if (lyric !== (note.lyric ?? '')) changes.lyric = lyric;
    if (pitch !== String(note.pitch ?? '')) changes.pitch = Number(pitch);
    await onedit(changes);
  }
</script>

<form class="note-editor" onsubmit={submit}>
  <div class="editor-heading"><span class="eyebrow">所选音符</span><span class="position">{note.start_tick} — {note.end_tick} tick</span></div>
  <div class="fields">
    <label>歌词<input aria-label="歌词" bind:value={lyric} {disabled} maxlength="1024" /></label>
    <label>音高 MIDI<input aria-label="音高 MIDI" type="number" min="56" max="72" step="1" value={pitch} oninput={(event) => { pitch = event.currentTarget.value; }} {disabled} required /></label>
    <button class="primary" type="submit" disabled={disabled || !changed}>应用音符修改</button>
    <span class="draft-status">{changed ? '有未提交修改' : '与工程一致'}</span>
  </div>
</form>

<style>
  .note-editor { padding: 22px 24px 26px; border-top: 1px solid var(--line); }
  .editor-heading { display: flex; gap: 24px; align-items: center; margin-bottom: 16px; }
  .position { color: var(--muted); font: 11px ui-monospace, monospace; }
  .fields { display: flex; gap: 14px; align-items: end; flex-wrap: wrap; }
  label { display: grid; gap: 7px; font-size: 12px; color: var(--muted); }
  input { width: 150px; }
  .draft-status { font-size: 11px; color: var(--muted); padding-bottom: 10px; }
</style>
