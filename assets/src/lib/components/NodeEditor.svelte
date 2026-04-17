<script lang="ts">
  import { SvelteFlow, Background, Controls } from "@xyflow/svelte";
  
  import DynamicNode from "./node/DynamicNode.svelte";
  import { getAllNodeTypes } from "$lib/stores/node_registry";
  import {
    stepDefToTemplateNode,
    genEdgeId,
    sflowToGraphPayload,
    type SFlowNode,
    type SFlowEdge,
  } from "$lib/utils";
  import type { EquinoxBridge } from "$lib/bridge";

  let { bridge }: { bridge: EquinoxBridge } = $props();

  let nodes = $state<SFlowNode[]>([]);
  let edges = $state<SFlowEdge[]>([]);
  let stepDefs = $state<any[]>([]);

  let nodeTypes = $derived.by(() => {
    const registered = getAllNodeTypes();
    return { ...registered, dynamic: DynamicNode };
  });

  // Example placeholder definition
  $effect(() => {
    if (stepDefs.length === 0) {
      stepDefs = [
        { name: "DiffSinger", module: "Elixir.DiffSinger", inputs: ["notes"], outputs: ["mel"] },
        { name: "Vocoder", module: "Elixir.Vocoder", inputs: ["mel"], outputs: ["audio"] }
      ];
    }
  });

  let syncPending = false;

  function scheduleSync() {
    if (syncPending) return;
    syncPending = true;
    queueMicrotask(() => {
      syncPending = false;
      const { nodes: ns, edges: es } = sflowToGraphPayload(nodes, edges);
      // bridge.pushEvent("synth_graph_update", { nodes: ns, edges: es });
    });
  }

  function addNode(stepDef: any) {
    const n = stepDefToTemplateNode(stepDef);
    n.position = {
      x: 50 + Math.random() * 100,
      y: 50 + Math.random() * 100,
    };
    nodes = [...nodes, n];
    scheduleSync();
  }

  function onConnect(e: any) {
    const edge: SFlowEdge = {
      id: genEdgeId(e.source, e.sourceHandle, e.target, e.targetHandle),
      source: e.source,
      sourceHandle: e.sourceHandle,
      target: e.target,
      targetHandle: e.targetHandle,
    };
    edges = [...edges, edge];
    scheduleSync();
  }
</script>

<div class="h-full w-full flex flex-col bg-zinc-800 text-white">
  <div class="p-2 bg-zinc-900 border-b border-zinc-700 flex justify-between items-center">
    <h2 class="text-sm font-bold text-amber-500 m-0">Topology Nodes</h2>
    <div class="flex gap-2">
      {#each stepDefs as step}
        <button
          class="px-2 py-1 bg-zinc-700 text-zinc-300 hover:text-white rounded text-xs cursor-pointer border border-zinc-600 hover:border-zinc-400"
          onclick={() => addNode(step)}
        >
          + {step.name}
        </button>
      {/each}
    </div>
  </div>
  <div class="flex-1 relative">
    <SvelteFlow
      {nodes}
      {edges}
      {nodeTypes}
      onconnect={onConnect}
      ondelete={(params) => {
        if (params.edges && params.edges.length > 0) {
          const deletedIds = new Set(params.edges.map(e => e.id));
          edges = edges.filter(e => !deletedIds.has(e.id));
          scheduleSync();
        }
        if (params.nodes && params.nodes.length > 0) {
          const deletedIds = new Set(params.nodes.map(n => n.id));
          nodes = nodes.filter(n => !deletedIds.has(n.id));
          scheduleSync();
        }
      }}
      fitView
      colorMode="dark"
    >
      <Background bgColor="#27272a" patternColor="#3f3f46" />
      <Controls />
    </SvelteFlow>
  </div>
</div>