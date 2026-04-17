<script lang="ts">
  import { SvelteFlow, Background, Controls } from "@xyflow/svelte";
  import type { Node, Edge } from "@xyflow/svelte";
  import type { Position } from "./node/position";
  import type { EquinoxBridge } from "$lib/bridge";

  if (typeof window !== "undefined" && typeof (window as any).process === "undefined") {
    (window as any).process = { env: { NODE_ENV: "production" } };
  }

  import TrackNode from "./arranger/TrackNode.svelte";
  import OutputNode from "./arranger/OutputNode.svelte";

  let { bridge, payload } = $props();

  const nodeTypes = {
    synth: TrackNode,
    external_audio: TrackNode,
    output_with_panel: OutputNode,
  };

  type SynthNodeMap = Record<string, {
    id: string; type: string; label: string; provider_id: string;
    note_count?: number; volume: number; muted: boolean; solo: boolean;
    position?: Position;
  }>;

  type ExternalNodeMap = Record<string, {
    id: string; type: string; label: string; source_ref?: string;
    volume: number; muted: boolean; solo: boolean;
    position?: Position;
  }>;

  type OutputNodeData = { id: string; label: string; volume: number; muted: boolean; position?: Position };

  type EdgeData = { id: string; source: string; target: string };

  type ArrangerState = {
    output_node: OutputNodeData;
    synth_nodes: SynthNodeMap;
    external_nodes: ExternalNodeMap;
    edges: EdgeData[];
  };

  let nodes = $state.raw<Node[]>([]);
  let edges = $state.raw<Edge[]>([]);
  let externalCounter = $state(0);

  function buildNodes(state: ArrangerState): Node[] {
    // Apply Node with dynamic.
    const n: Node[] = [];
    const synths = Object.values(state.synth_nodes ?? {});
    const externals = Object.values(state.external_nodes ?? {});

    for (const sn of synths) {
      n.push({
        id: sn.id,
        type: "synth",
        position: sn.position ?? { x: 50, y: n.length * 160 + 30 },
        data: {
          ...sn,
          deletable: false,
          onDelete: null,
          onPropertyChange: updateNodeProperty,
        },
        draggable: true,
      });
    }

    for (const en of externals) {
      n.push({
        id: en.id,
        type: "external_audio",
        position: en.position ?? { x: 50, y: n.length * 160 + 30 },
        data: {
          ...en,
          deletable: true,
          onDelete: deleteExternalTrack,
          onPropertyChange: updateNodeProperty,
        },
        draggable: true,
      });
    }

    n.push({
      id: state.output_node.id,
      type: "output_with_panel",
      position: state.output_node.position ?? { x: 400, y: 80 },
      // style: `min-w-56`,
      data: {
        ...state.output_node,
        onPropertyChange: updateNodeProperty,
        onPlay: play,
        onExport: exportAudio,
      },
      draggable: true,
    });

    return n;
  }

  function buildEdges(state: ArrangerState): Edge[] {
    return (state.edges ?? []).map((e) => ({
      id: e.id,
      source: e.source,
      target: e.target,
      animated: e.target === "output",
    }));
  }

  function syncState(state: ArrangerState) {
    console.log(state);
    nodes = buildNodes(state);
    edges = buildEdges(state);
  }

  $effect(() => {
    if (payload) {
      syncState(payload as ArrangerState);
    }
  });

  $effect(() => {
    if (!bridge) return;
    bridge.handleEvent("state_updated", (state: ArrangerState) => {
      syncState(state);
    });
    bridge.handleEvent("mix_result", (result: any) => {
      console.log("Mix result:", result);
    });
    bridge.handleEvent("export_result", (result: any) => {
      console.log("Export result:", result);
    });
  });

  function addExternalTrack() {
    externalCounter++;
    const label = `Audio Track ${externalCounter}`;
    bridge.pushEvent("add_external_node", { label });
  }

  function deleteExternalTrack(id: string) {
    bridge.pushEvent("remove_external_node", { id });
  }

  function updateNodeProperty(nodeId: string, props: Record<string, any>) {
    bridge.pushEvent("update_node_properties", { node_id: nodeId, props });
  }

  function play() {
    bridge.pushEvent("mix", {});
  }

  function exportAudio() {
    bridge.pushEvent("export", { path: "output.wav" });
  }

  function handleNodeDragStop({ targetNode }: { targetNode: Node | null }) {
    if (!targetNode) return;
    const pos = targetNode.position;
    bridge.pushEvent("update_node_properties", {
      node_id: targetNode.id,
      props: { position: { x: Math.round(pos.x), y: Math.round(pos.y) } },
    });
  }

  function handleConnect(connection: any) {
    const id = `e_${connection.source}_${connection.target}`;
    bridge.pushEvent("add_edge", {
      id,
      source: connection.source,
      target: connection.target,
    });
  }

  function handleDelete({ nodes: deletedNodes, edges: deletedEdges }: { nodes: Node[]; edges: Edge[] }) {
    for (const edge of deletedEdges) {
      bridge.pushEvent("remove_edge", { id: edge.id });
    }
  }
</script>

<div class="p-4 border border-slate-200 rounded-lg font-sans bg-white">
  <div class="flex items-center justify-between mb-3">
    <h3 class="m-0 text-base text-gray-800">Arranger Mixer</h3>
    <button
      class="px-3 py-1 bg-emerald-600 hover:bg-emerald-500 text-white text-xs rounded cursor-pointer border-none font-medium transition-colors"
      onclick={addExternalTrack}
    >
      + Add Audio Track
    </button>
  </div>
  <div class="relative rounded overflow-hidden bg-neutral-800 h-125 text-black">
    <SvelteFlow
      bind:nodes
      bind:edges
      {nodeTypes}
      onnodedragstop={handleNodeDragStop}
      onconnect={handleConnect}
      ondelete={handleDelete}
      fitView
    >
      <Background />
      <Controls />
    </SvelteFlow>
  </div>
</div>
