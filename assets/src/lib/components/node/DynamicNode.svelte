<script lang="ts">
  import type { NodeProps, Node } from "@xyflow/svelte";
  import { Handle, Position } from "@xyflow/svelte";

  type PortDef = { name: string; type: string };
  type DynamicData = {
    label: string;
    module?: string;
    inputs: PortDef[];
    outputs: PortDef[];
    properties: Record<string, any>;
  };

  let { id, data }: NodeProps<Node<DynamicData>> = $props();
</script>

<div
  class="min-w-44 rounded-lg border border-violet-600/80 bg-slate-800 text-white shadow-md font-sans"
>
  {#each data.inputs as port, i}
    <Handle
      type="target"
      position={Position.Left}
      id={port.name}
      style="top: {(i + 1) * 28}px;"
      class="bg-violet-400! w-2.5! h-2.5!"
    />
  {/each}

  {#each data.outputs as port, i}
    <Handle
      type="source"
      position={Position.Right}
      id={port.name}
      style="top: {(i + 1) * 28}px;"
      class="bg-violet-400! w-2.5! h-2.5!"
    />
  {/each}

  <div
    class="flex items-center justify-between px-2.5 py-1.5 bg-violet-700/60 rounded-t-lg cursor-grab active:cursor-grabbing"
  >
    <span class="text-xs font-semibold text-violet-100 truncate">{data.label}</span>
    {#if data.module}
      <span class="text-[9px] text-violet-300/60 ml-2 shrink-0">{data.module}</span>
    {/if}
  </div>

  <div class="px-2.5 py-2 space-y-1">
    {#each data.inputs as port}
      <div class="text-[10px] text-slate-400 flex items-center gap-1">
        <span class="inline-block w-1.5 h-1.5 rounded-full bg-violet-400"></span>
        <span class="truncate">{port.name}</span>
        <span class="text-slate-500 ml-auto">{port.type}</span>
      </div>
    {/each}

    {#each Object.entries(data.properties || {}) as [key, val]}
      <div class="text-[10px] text-slate-400 flex items-center gap-1 nodrag">
        <span class="text-violet-300/80 font-mono">{key}</span>
        <span class="text-slate-500 ml-auto">{String(val)}</span>
      </div>
    {/each}

    {#each data.outputs as port}
      <div class="text-[10px] text-slate-400 flex items-center gap-1">
        <span class="inline-block w-1.5 h-1.5 rounded-full bg-violet-400"></span>
        <span class="truncate">{port.name}</span>
        <span class="text-slate-500 ml-auto">{port.type}</span>
      </div>
    {/each}
  </div>
</div>
