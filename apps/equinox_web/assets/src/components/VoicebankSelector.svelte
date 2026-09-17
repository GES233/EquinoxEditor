<script lang="ts">
  // 声库选择器：纯展示/意图组件。
  // currentId 始终来自权威快照；下拉选择只是本地草稿，
  // 只有点击「应用声库」才通过 onselect 提交意图。组件不访问后端、
  // 不创建 socket、不模拟绑定成功，也不更改任何工程状态。
  import type { Voicebank } from '../lib/types';

  interface Props {
    voicebanks: Voicebank[];
    currentId: string | null;
    status: 'loading' | 'ready' | 'error';
    error?: string;
    disabled?: boolean;
    onselect: (id: string) => void;
    onretry: () => void;
  }

  let {
    voicebanks,
    currentId,
    status,
    error = undefined,
    disabled = false,
    onselect,
    onretry,
  }: Props = $props();

  const instanceId = $props.id();
  const selectId = `${instanceId}-select`;
  const warningId = `${instanceId}-missing`;
  function modeName(mode: string | null) {
    return mode === 'demo' ? '演示' : mode === 'stock' ? '原版' : mode === 'modified' ? '修改版' : mode;
  }

  // 本地草稿：与 props 的 currentId / voicebanks 变化协调，
  // 始终回齐到权威绑定，不留下旧选项。$effect.pre 在首次渲染前
  // 完成初始化，因此草稿不会闪现初始空值。
  let draftId = $state('');

  $effect.pre(() => {
    void voicebanks;
    draftId = currentId ?? '';
  });

  let currentVoicebank = $derived(
    currentId === null ? null : (voicebanks.find((v) => v.id === currentId) ?? null),
  );
  let currentMissing = $derived(status === 'ready' && currentId !== null && currentVoicebank === null);
  let canApply = $derived(
    status === 'ready' && !disabled && voicebanks.some((v) => v.id === draftId) && draftId !== (currentId ?? ''),
  );

  function apply() {
    if (!canApply) return;
    onselect(draftId);
  }
</script>

<aside class="voicebank-selector" aria-label="声库">
  <h2 class="vbs-title">声库</h2>

  {#if status === 'loading'}
    <p class="vbs-status" role="status">正在加载声库…</p>
  {:else if status === 'error'}
    <div class="vbs-error" role="alert">
      <p>声库列表加载失败。</p>
      {#if error}<p class="vbs-error-detail">{error}</p>{/if}
      <button type="button" class="vbs-retry" {disabled} onclick={onretry}>重试</button>
    </div>
  {:else if voicebanks.length === 0}
    <p class="vbs-status" role="status">没有可用的声库。</p>
    {#if currentId !== null}<p class="vbs-current-missing" role="alert">当前绑定的声库不可用。</p>{/if}
  {:else}
    <div class="vbs-current">
      {#if currentVoicebank}
        <p class="vbs-current-name">
          当前绑定：<strong>{currentVoicebank.name}</strong>
          {#if currentVoicebank.mode}（{modeName(currentVoicebank.mode)}）{/if}
        </p>
      {:else if currentId !== null}
        <p class="vbs-current-missing" role="alert">
          当前绑定的声库不可用，请重新选择后应用。
        </p>
      {:else}
        <p class="vbs-current-none">尚未绑定声库。</p>
      {/if}
    </div>

    <div class="vbs-field">
      <label class="vbs-label" for={selectId}>选择声库</label>
      <select
        id={selectId}
        class="vbs-select"
        bind:value={draftId}
        {disabled}
        aria-describedby={currentMissing ? warningId : undefined}
      >
        <option value="" disabled hidden>请选择…</option>
        {#if currentMissing}<option value={currentId ?? ''} disabled>当前绑定不可用</option>{/if}
        {#each voicebanks as vb (vb.id)}
          <option value={vb.id}>{vb.name}{#if vb.mode}（{modeName(vb.mode)}）{/if}</option>
        {/each}
      </select>
    </div>

    {#if currentMissing}
      <p class="vbs-warning" id={warningId} role="alert">
        注意：下列表中未包含当前绑定的声库，应用选择后将以新声库替换。
      </p>
    {/if}

    <button
      type="button"
      class="vbs-apply"
      disabled={!canApply}
      onclick={apply}
    >
      应用声库
    </button>
  {/if}
</aside>

<style>
  .voicebank-selector {
    width: 240px;
    box-sizing: border-box;
    padding: 12px 14px;
    border: 1px solid var(--line, #d8d4cc);
    border-radius: 8px;
    background: var(--panel, #fbfaf7);
    color: var(--ink, #2c2a26);
    font-size: 13px;
    line-height: 1.5;
  }

  .vbs-title {
    margin: 0 0 8px;
    font-size: 12px;
    font-weight: 600;
    letter-spacing: 0.08em;
    color: var(--muted, #6f6a60);
  }

  .vbs-status {
    margin: 4px 0;
    color: var(--muted, #6f6a60);
  }

  .vbs-current {
    margin-bottom: 10px;
    padding-bottom: 8px;
    border-bottom: 1px solid var(--line, #d8d4cc);
  }

  .vbs-current-name {
    margin: 0;
  }

  .vbs-current-name strong {
    color: var(--accent, #4a6b5c);
    font-weight: 600;
  }

  .vbs-current-none {
    margin: 0;
    color: var(--muted, #6f6a60);
  }

  .vbs-current-missing {
    margin: 0;
    color: var(--warning, #9a6b2f);
  }

  .vbs-field {
    margin-bottom: 10px;
  }

  .vbs-label {
    display: block;
    margin-bottom: 4px;
    font-size: 12px;
    color: var(--muted, #6f6a60);
  }

  .vbs-select {
    width: 100%;
    box-sizing: border-box;
    padding: 5px 8px;
    border: 1px solid var(--line, #d8d4cc);
    border-radius: 6px;
    background: var(--surface, #f4f2ec);
    color: var(--ink, #2c2a26);
    font-size: 13px;
  }

  .vbs-select:focus-visible,
  .vbs-apply:focus-visible,
  .vbs-retry:focus-visible {
    outline: 2px solid var(--accent, #4a6b5c);
    outline-offset: 1px;
  }

  .vbs-warning {
    margin: 0 0 10px;
    font-size: 12px;
    color: var(--warning, #9a6b2f);
  }

  .vbs-error p {
    margin: 0 0 6px;
  }

  .vbs-error-detail {
    font-size: 12px;
    color: var(--muted, #6f6a60);
    word-break: break-all;
  }

  .vbs-apply,
  .vbs-retry {
    width: 100%;
    padding: 6px 10px;
    border: 1px solid var(--accent, #4a6b5c);
    border-radius: 6px;
    background: var(--accent, #4a6b5c);
    color: var(--surface, #f4f2ec);
    font-size: 13px;
    cursor: pointer;
  }

  .vbs-apply:disabled,
  .vbs-retry:disabled {
    border-color: var(--line, #d8d4cc);
    background: var(--line, #d8d4cc);
    color: var(--muted, #6f6a60);
    cursor: not-allowed;
  }

  .vbs-apply:not(:disabled):hover,
  .vbs-retry:not(:disabled):hover {
    filter: brightness(1.1);
  }
</style>
