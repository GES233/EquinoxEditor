<script lang="ts">
  import { onMount } from 'svelte';
  import editorMark from '../../../../artwoks/editor_dark.svg';
  import VoicebankSelector from './components/VoicebankSelector.svelte';
  import PitchWorkspace from './components/PitchWorkspace.svelte';
  import NoteEditor from './components/NoteEditor.svelte';
  import OutputControls from './components/OutputControls.svelte';
  import ComponentGallery from './ComponentGallery.svelte';
  import { ProjectClient } from './lib/project-client';
  import type { CheckReport, CheckState, ConnectionState, EditIntent, PitchPoint, Snapshot, Voicebank, OutputExtraction } from './lib/types';

  const gallery = new URLSearchParams(location.search).has('components');
  let snapshot = $state<Snapshot | null>(null);
  let connection = $state<ConnectionState>('connecting');
  let voicebanks = $state<Voicebank[]>([]);
  let voicebankStatus = $state<'loading' | 'ready' | 'error'>('loading');
  let voicebankError = $state('');
  let error = $state('');
  let busy = $state(false);
  let uncertain = $state(false);
  let checkReport = $state<CheckReport | null>(null);
  let checkState = $state<CheckState>('unchecked');
  let checking = $state(false);
  let checkError = $state('');
  let notice = $state('');
  let output = $state<OutputExtraction | null>(null);
  let extracting = $state(false);
  let outputNotice = $state('');
  let revision = 0;
  let client: ProjectClient | undefined;
  let generation = 0;
  let track = $derived(snapshot?.tracks[0]);
  let note = $derived(track?.notes[0]);
  let disabled = $derived(connection !== 'connected' || busy || uncertain);
  let currentVoicebankId = $derived(track?.voicebank ?
    (voicebanks.find((v) => v.digest === track?.voicebank?.digest && v.engine === track?.voicebank?.engine)?.id ?? '__unavailable__') : null);

  function invalidateCheck() {
    revision++;
    checkReport = null;
    checkState = 'unchecked';
    notice = '';
    output = null;
  }

  async function extractOutput() {
    if (disabled || extracting || checking || !client || !track) return;
    const active = client, started = revision, trackId = track.id;
    extracting = true; outputNotice = '';
    try {
      const result = await active.extractOutput(trackId);
      if (active === client && started === revision && result.token.history_pin === snapshot?.history_pin) output = result;
    } catch (reason) {
      if (active === client && started === revision) outputNotice = (reason as Error).message;
    } finally { if (active === client) extracting = false; }
  }

  async function changeOutput(channel?: 'duration' | 'pitch', values?: number[] | PitchPoint[], digest?: string, patchId?: string) {
    if (disabled || extracting || checking || !client || !track || !note || !output) return;
    const active = client, token = output.token, trackId = track.id, noteId = note.id;
    busy = true; error = ''; outputNotice = '';
    try {
      if (patchId) {
        const result = await active.repatchOutput(trackId, patchId, token);
        if (active === client) outputNotice = result.result.status === 'degraded' ? '修改已无法沿用，原干预保留，请重新编辑或移除。' : '已沿用修改。';
      } else if (channel && values && digest) {
        await active.putOutput(trackId, noteId, channel, values, digest, token);
      }
    } catch (reason) {
      if (active === client) { error = (reason as Error).message; uncertain = !error.startsWith('操作未生效：'); }
    } finally { if (active === client) busy = false; }
    if (active === client && !uncertain) {
      const message = outputNotice;
      await extractOutput();
      if (active === client && message) outputNotice = message;
    }
  }

  async function check() {
    if (disabled || checking || extracting || !client || !snapshot) return;
    const active = client;
    const started = revision;
    const pin = snapshot.history_pin;
    checking = true;
    checkState = 'checking';
    checkError = '';
    try {
      const result = await active.check();
      if (active !== client || revision !== started || result.history_pin !== snapshot?.history_pin || result.history_pin !== pin) return;
      checkReport = result;
      checkState = result.status === 'ok' ? 'ok' : 'failed';
    } catch (reason) {
      if (active === client && revision === started) {
        checkState = 'error'; checkError = (reason as Error).message;
      }
    } finally { if (active === client) checking = false; }
  }

  async function applyPitch(points: PitchPoint[], patchId?: string) {
    if (disabled || !client || !track || !note || !snapshot) return;
    const active = client;
    const started = revision;
    const pin = snapshot.history_pin;
    const trackId = track.id;
    const noteId = note.id;
    const noteStart = note.start_tick;
    busy = true; error = '';
    try {
      const token = await active.preflight(trackId, noteId);
      if (active !== client || revision !== started || token.history_pin !== pin) {
        await active.refresh();
        error = '工程已变化，未提交音高草稿。请在当前音符上重新确认。';
        return;
      }
      invalidateCheck();
      await active.edit(patchId ? { command: 'replace_pitch', track_id: trackId, patch_id: patchId, points } :
        { command: 'mount_pitch', track_id: trackId, note_id: noteId, points: points.map(([tick, midi]) => [noteStart + tick, midi]), token });
    } catch (reason) {
      error = (reason as Error).message;
      uncertain = !error.startsWith('操作未生效：');
    } finally { busy = false; }
  }

  async function loadVoicebanks() {
    const active = client;
    voicebankStatus = 'loading';
    try {
      const result = await active!.voicebanks();
      if (client !== active) return;
      voicebanks = result;
      voicebankStatus = 'ready';
    } catch (reason) {
      if (client !== active) return;
      voicebankError = (reason as Error).message;
      voicebankStatus = 'error';
    }
  }

  async function connect() {
    generation++;
    const ownGeneration = generation;
    client?.close();
    connection = 'connecting';
    invalidateCheck(); checking = false; extracting = false;
    error = '';
    client = new ProjectClient({
      snapshot: (value) => { if (ownGeneration === generation) { if (snapshot?.history_pin !== value.history_pin) invalidateCheck(); snapshot = value; uncertain = false; } },
      invalidated: invalidateCheck,
      connection: (value) => {
        if (ownGeneration !== generation) return;
        connection = value;
        if (value !== 'connected') invalidateCheck();
        if (value === 'connected') void loadVoicebanks();
      },
      error: (message) => { if (ownGeneration === generation) { error = message; uncertain = true; } },
    });
    try { await client.connect(); }
    catch (reason) { if (ownGeneration === generation) { error = (reason as Error).message; connection = 'disconnected'; } }
  }

  onMount(() => {
    if (!gallery) void connect();
    return () => { generation++; client?.close(); };
  });

  async function edit(intent: EditIntent) {
    if (disabled || !client) return;
    busy = true;
    error = '';
    const previousReport = checkReport;
    invalidateCheck();
    try {
      const result = await client.edit(intent);
      if (result.results) notice = result.results.some((entry) => entry.status === 'degraded') ?
        '无法沿用：原调校已保留，请重新编辑或移除。' : '已沿用到当前事实，请重新检查。';
      if (previousReport && result.results?.every((entry) => entry.status === 'degraded') && previousReport.history_pin === snapshot?.history_pin) {
        checkReport = previousReport;
        checkState = previousReport.status === 'ok' ? 'ok' : 'failed';
      }
    }
    catch (reason) {
      error = (reason as Error).message;
      // 未知提交结果不能自动重放；刷新权威状态后才允许继续。
      uncertain = !error.startsWith('操作未生效：');
    } finally { busy = false; }
  }
</script>

{#if gallery}
  <ComponentGallery />
{:else}
  <div class="workspace">
    <header class="topbar">
      <div class="brand"><img class="brand-mark" src={editorMark} alt="" width="34" height="32" /><span>EQUINOX</span><span class="brand-divider">/</span><span class="project-name">一枚音符</span></div>
      <div class="history-actions">
        <button aria-label="撤销" disabled={disabled || !snapshot?.can_undo} onclick={() => edit({ command: 'undo' })}>↶ 撤销</button>
        <button aria-label="重做" disabled={disabled || !snapshot?.can_redo} onclick={() => edit({ command: 'redo' })}>↷ 重做</button>
      </div>
      <span class="connection" class:online={connection === 'connected'} role="status">{connection === 'connected' ? '已连接' : connection === 'connecting' ? '正在连接' : '连接已断开'}</span>
    </header>

    <div class="project-strip"><span class="eyebrow">工作区 / 01</span><span>演示工程 · 编辑保留在本次服务会话中</span><a href="/?components">组件样例 ↗</a></div>

    {#if error || connection === 'disconnected'}
      <div class="error-banner" role="alert"><span>{error || '连接已断开，正在尝试恢复。'}</span>{#if uncertain || connection !== 'connected'}<button onclick={connect}>重新连接并核对</button>{/if}</div>
    {/if}

    <div class="editor-layout">
      <aside class="sidebar">
        <div class="sidebar-heading"><span class="eyebrow">轨道</span><span>01</span></div>
        <div class="track-item"><span class="track-dot"></span><div><strong>{track?.name ?? '暂无轨道'}</strong><small>{track ? `${track.notes.length} 枚音符` : '可使用重做恢复'}</small></div><span class="track-number">01</span></div>
        <VoicebankSelector {voicebanks} currentId={currentVoicebankId} status={voicebankStatus} error={voicebankError} disabled={disabled || !track} onretry={loadVoicebanks} onselect={(voicebank_id) => { if (track) void edit({ command: 'rebind_voicebank', track_id: track.id, voicebank_id }); }} />
        <div class="sidebar-note">演示声库用于验证编辑。<br />本阶段不提供合成与播放。</div>
      </aside>

      <main class="editor">
        <div class="editor-toolbar"><div><span class="eyebrow">钢琴卷帘</span><h1>{track?.name ?? '编辑工作区'}</h1></div><div class="toolbar-meta"><span>4/4</span><span>120 BPM</span><span>1/4 拍吸附</span></div></div>
        {#key snapshot?.history_pin}
          <PitchWorkspace {track} historyPin={snapshot?.history_pin ?? -1} {disabled} report={checkReport} {checkState} {checking} {checkError} {notice}
            oncheck={check} onapply={applyPitch}
            onremove={() => { if (track && note) void edit({ command: 'unmount_pitch', track_id: track.id, note_id: note.id }); }}
            onrepatch={(patch_ids) => { if (track) void edit({ command: 'repatch', track_id: track.id, patch_ids }); }}
            onmove={(moved, span) => { if (track) void edit({ command: 'move_note', track_id: track.id, note_id: moved.id, span }); }} />
        {/key}
        {#if note && track}
          <OutputControls {output} noteId={note.id} pins={track.pins.filter((pin) => pin.anchor.refs.includes(note!.id))}
            {disabled} busy={extracting || checking} notice={outputNotice}
            onextract={extractOutput} onput={(channel, values, digest) => changeOutput(channel, values, digest)}
            onrepatch={(patchId) => changeOutput(undefined, undefined, undefined, patchId)}
            onremove={(channel) => edit({ command: 'unmount_output', track_id: track!.id, note_id: note!.id, channel })} />
          {#key snapshot?.history_pin}
            <NoteEditor {note} {disabled} onedit={(changes) => edit({ command: 'edit_note', track_id: track!.id, note_id: note!.id, changes })} />
          {/key}
        {:else}
          <div class="empty-editor">{snapshot ? '当前没有音符，可使用重做恢复起手音符。' : '正在读取工程…'}</div>
        {/if}
      </main>
    </div>

    <footer><span>{busy ? '正在提交编辑…' : uncertain ? '等待核对工程状态' : '编辑完成后可撤销；刷新页面会重新读取当前工程'}</span><span data-testid="history-pin">版本 {snapshot?.history_pin ?? '—'}</span></footer>
  </div>
{/if}
