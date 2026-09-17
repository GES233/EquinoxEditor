<script lang="ts">
  import VoicebankSelector from './components/VoicebankSelector.svelte';
  import type { Voicebank } from './lib/types';

  const voicebanks: Voicebank[] = [
    { id: 'a', name: '演示声库 A', engine: 'mock', mode: 'demo', digest: 'a' },
    { id: 'b', name: '演示声库 B', engine: 'mock', mode: 'demo', digest: 'b' },
  ];
  let message = $state('尚未发出选择意图');
  let currentId = $state<string | null>('a');
  function select(id: string) { message = `收到选择意图：${id}（未连接工程）`; }
</script>

<main class="gallery">
  <a href="/">← 编辑工作区</a>
  <h1>声库选择器 · 状态样例</h1>
  <p>固定数据，仅验证展示和用户意图。选择不会自动改变当前绑定。</p>
  <p role="status">{message}</p>
  <button onclick={() => { currentId = currentId === 'a' ? 'b' : 'a'; }}>模拟权威绑定更新</button>
  <div class="examples">
    <section aria-label="正常样例"><h2>可选择</h2><VoicebankSelector {voicebanks} {currentId} status="ready" onselect={select} onretry={() => {}} /></section>
    <section aria-label="未绑定样例"><h2>未绑定</h2><VoicebankSelector {voicebanks} currentId={null} status="ready" onselect={select} onretry={() => {}} /></section>
    <section aria-label="缺失样例"><h2>绑定不可用</h2><VoicebankSelector {voicebanks} currentId="missing" status="ready" onselect={select} onretry={() => {}} /></section>
    <section aria-label="空样例"><h2>空列表</h2><VoicebankSelector voicebanks={[]} currentId={null} status="ready" onselect={select} onretry={() => {}} /></section>
    <section aria-label="加载样例"><h2>加载中</h2><VoicebankSelector voicebanks={[]} currentId={null} status="loading" onselect={select} onretry={() => {}} /></section>
    <section aria-label="错误样例"><h2>失败</h2><VoicebankSelector voicebanks={[]} currentId={null} status="error" error="声库查询失败" onselect={select} onretry={() => { message = '请求重新查询'; }} /></section>
    <section aria-label="禁用样例"><h2>提交中</h2><VoicebankSelector {voicebanks} currentId="a" status="ready" disabled onselect={select} onretry={() => {}} /></section>
  </div>
</main>

<style>
  .gallery { max-width: 1200px; margin: 50px auto; padding: 24px; }
  h1 { font-size: 26px; } h2 { font-size: 13px; font-weight: 500; }
  p { color: var(--muted); }
  .examples { display: flex; flex-wrap: wrap; gap: 28px; margin-top: 32px; align-items: start; }
</style>
