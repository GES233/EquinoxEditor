<script lang="ts">
  import type { NodeProps, Node } from "@xyflow/svelte";
  import { Handle, Position } from "@xyflow/svelte";

  type OutputData = {
    label: string;
    volume: number;
    muted: boolean;
    onPropertyChange?: (id: string, props: Record<string, any>) => void;
    onPlay?: () => void;
    onExport?: () => void;
  };

  let { id, data }: NodeProps<Node<OutputData>> = $props();

  function onVolumeInput(e: Event) {
    const val = parseFloat((e.target as HTMLInputElement).value);
    data.onPropertyChange?.(id, { volume: val });
  }
</script>

<div class="relative min-w-55 font-sans drop-shadow-xl">
  <Handle
    type="target"
    position={Position.Left}
    class="bg-amber-500! w-3.5! h-3.5! border-2! border-amber-950! z-10 hover:bg-amber-400! transition-colors"
  />

  <div
    class="rounded-xl border border-amber-700/80 bg-amber-900 overflow-hidden shadow-inner flex flex-col"
  >
    <div
      class="px-3 py-2 bg-linear-to-b from-amber-700 to-amber-800 border-b border-amber-600/50 shadow-sm cursor-grab active:cursor-grabbing"
    >
      <div
        class="text-sm font-bold text-center text-amber-50 tracking-wider drop-shadow-md"
      >
        {data.label}
      </div>
    </div>

    <div class="p-3 space-y-3 bg-amber-950/40">
      <div class="flex items-center gap-2">
        <span
          class="text-[11px] font-semibold text-amber-300/90 w-6 shrink-0 uppercase tracking-wide"
          >Vol</span
        >

        <input
          type="range"
          min="0"
          max="1"
          step="0.01"
          value={data.volume}
          oninput={onVolumeInput}
          class="flex-1 h-1.5 bg-amber-950/80 rounded-lg appearance-none cursor-pointer accent-amber-500 nodrag hover:accent-amber-400 transition-all"
        />
        <span
          class="text-xs font-mono text-amber-300 w-9 text-right tabular-nums"
        >
          {Math.round(data.volume * 100)}%
        </span>
      </div>

      <div class="flex gap-2 pt-1">
        <button
          class="flex-1 flex items-center justify-center gap-1.5 px-2 py-1.5 text-xs rounded-md cursor-pointer bg-emerald-600 hover:bg-emerald-500 active:bg-emerald-700 text-white font-medium transition-all border border-emerald-500/30 shadow-sm nodrag"
          onclick={data.onPlay}
        >
          <svg class="w-3 h-3 fill-current" viewBox="0 0 16 16"
            ><path d="M3 2v12l10-6z" /></svg
          >
          Play
        </button>

        <button
          class="flex-1 flex items-center justify-center gap-1.5 px-2 py-1.5 text-xs rounded-md cursor-pointer bg-slate-700 hover:bg-slate-600 active:bg-slate-800 text-slate-100 font-medium transition-all border border-slate-600/50 shadow-sm nodrag"
          onclick={data.onExport}
        >
          <svg class="w-3 h-3 fill-current" viewBox="0 0 16 16"
            ><path
              fill-rule="evenodd"
              d="M8 3a5 5 0 1 0 4.546 2.914.5.5 0 0 1 .908-.417A6 6 0 1 1 8 2v1z"
            /><path
              d="M8 4.466V.534a.25.25 0 0 1 .41-.192l2.36 1.966c.128.107.128.315 0 .422L8.41 4.658A.25.25 0 0 1 8 4.466z"
            /></svg
          >
          Export
        </button>
      </div>
    </div>
  </div>
</div>
