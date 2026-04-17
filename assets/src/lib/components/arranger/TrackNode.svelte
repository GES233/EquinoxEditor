<script lang="ts">
  import type { NodeProps, Node } from "@xyflow/svelte";
  import { Handle, Position } from "@xyflow/svelte";

  type TrackData = {
    label: string;
    provider_id?: string;
    source_ref?: string;
    note_count?: number;
    volume: number;
    muted: boolean;
    solo: boolean;
    deletable?: boolean;
    onDelete?: (id: string) => void;
    onPropertyChange?: (id: string, props: Record<string, any>) => void;
  };

  let { id, data }: NodeProps<Node<TrackData>> = $props();

  function toggleMute() {
    data.onPropertyChange?.(id, { muted: !data.muted });
  }

  function toggleSolo() {
    data.onPropertyChange?.(id, { solo: !data.solo });
  }

  function onVolumeInput(e: Event) {
    const val = parseFloat((e.target as HTMLInputElement).value);
    data.onPropertyChange?.(id, { volume: val });
  }
</script>

<div
  class="min-w-48 rounded-lg border border-slate-600 bg-slate-700 text-white shadow-md"
>
  <Handle
    type="source"
    position={Position.Right}
    class="bg-emerald-500! w-2.5! h-2.5!"
  />

  <div
    class="flex items-center justify-between px-2.5 py-1.5 bg-slate-800 rounded-t-lg"
  >
    <span class="text-xs font-semibold text-slate-200 truncate"
      >{data.label}</span
    >
    {#if data.deletable && data.onDelete}
      <button
        class="text-slate-400 hover:text-red-400 text-xs leading-none ml-2 cursor-pointer"
        onclick={() => data.onDelete!(id)}
      >
        ✕
      </button>
    {/if}
  </div>

  <div class="px-2.5 py-2 space-y-1.5">
    {#if data.provider_id}
      <div class="text-[10px] text-slate-400">
        Synth · {data.note_count ?? 0} notes
      </div>
    {/if}
    {#if data.source_ref}
      <div class="text-[10px] text-slate-400 truncate">
        {data.source_ref}
      </div>
    {/if}

    <div class="flex items-center gap-1.5 nodrag nopan">
      <span class="text-[10px] text-slate-400 w-8 shrink-0">Vol</span>
      <input
        type="range"
        min="0"
        max="1"
        step="0.01"
        value={data.volume}
        oninput={onVolumeInput}
        class="flex-1 h-1 accent-emerald-500"
      />
      <span class="text-[10px] text-slate-400 w-7 text-right"
        >{(data.volume * 100) | 0}%</span
      >
    </div>

    <div class="flex gap-1">
      <button
        class="px-1.5 py-0.5 text-[10px] rounded cursor-pointer border transition-colors {data.muted
          ? 'bg-red-500/30 border-red-500 text-red-300'
          : 'bg-slate-600 border-slate-500 text-slate-300 hover:bg-slate-500'}"
        onclick={toggleMute}
      >
        M
      </button>
      <button
        class="px-1.5 py-0.5 text-[10px] rounded cursor-pointer border transition-colors {data.solo
          ? 'bg-yellow-500/30 border-yellow-500 text-yellow-300'
          : 'bg-slate-600 border-slate-500 text-slate-300 hover:bg-slate-500'}"
        onclick={toggleSolo}
      >
        S
      </button>
    </div>
  </div>
</div>
