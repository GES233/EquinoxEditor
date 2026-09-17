<script lang="ts">
  import { onMount } from 'svelte';
  import editorMark from '../../../../artwoks/editor_dark.svg';
  import VoicebankSelector from './components/VoicebankSelector.svelte';
  import PianoRoll from './components/PianoRoll.svelte';
  import NoteEditor from './components/NoteEditor.svelte';
  import ComponentGallery from './ComponentGallery.svelte';
  import { ProjectClient } from './lib/project-client';
  import type { ConnectionState, EditIntent, Snapshot, Voicebank } from './lib/types';

  const gallery = new URLSearchParams(location.search).has('components');
  let snapshot = $state<Snapshot | null>(null);
  let connection = $state<ConnectionState>('connecting');
  let voicebanks = $state<Voicebank[]>([]);
  let voicebankStatus = $state<'loading' | 'ready' | 'error'>('loading');
  let voicebankError = $state('');
  let error = $state('');
  let busy = $state(false);
  let uncertain = $state(false);
  let client: ProjectClient | undefined;
  let generation = 0;
  let track = $derived(snapshot?.tracks[0]);
  let note = $derived(track?.notes[0]);
  let disabled = $derived(connection !== 'connected' || busy || uncertain);
  let currentVoicebankId = $derived(track?.voicebank ?
    (voicebanks.find((v) => v.digest === track?.voicebank?.digest && v.engine === track?.voicebank?.engine)?.id ?? '__unavailable__') : null);

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
    error = '';
    client = new ProjectClient({
      snapshot: (value) => { if (ownGeneration === generation) { snapshot = value; uncertain = false; } },
      connection: (value) => {
        if (ownGeneration !== generation) return;
        connection = value;
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
    try { await client.edit(intent); }
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
        <PianoRoll {track} historyPin={snapshot?.history_pin ?? -1} {disabled} onmove={(moved, span) => { if (track) void edit({ command: 'move_note', track_id: track.id, note_id: moved.id, span }); }} />
        {#if note && track}
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
