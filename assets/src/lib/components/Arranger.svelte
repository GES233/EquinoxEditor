<script lang="ts">
  import { SvelteFlow, Background, Controls } from "@xyflow/svelte";
  import type { Node, Edge } from "@xyflow/svelte";
  import { onMount } from "svelte";
  import type { Position } from "./node/position";
  import type {
    EquinoxBridge,
    ProjectData,
    EditorContextData,
    TrackData,
    SegmentData,
    EditorScope,
  } from "$lib/bridge";
  import { requestEditorContextChange } from "$lib/editor_context";

  if (typeof window !== "undefined" && typeof (window as any).process === "undefined") {
    (window as any).process = { env: { NODE_ENV: "production" } };
  }

  import TrackNode from "./arranger/TrackNode.svelte";
  import OutputNode from "./arranger/OutputNode.svelte";

  type SynthNodeMap = Record<string, {
    id: string; type: string; label: string; provider_id: string;
    note_count?: number; volume: number; muted: boolean; solo: boolean;
    isActive: boolean;
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

  let { bridge, payload }: { bridge: EquinoxBridge; payload?: ArrangerState } = $props();

  let project = $state<ProjectData | null>(null);
  let editorContext = $state<EditorContextData | null>(null);
  let arrangerStepDefs = $state<any[]>([]);

  let scopeLabel = $derived(scopeToLabel(editorContext?.scope ?? "track"));
  let timelineMaxTick = $derived.by(() => resolveTimelineMaxTick(project));
  let timelineRows = $derived.by(() => buildTimelineRows(project, timelineMaxTick));

  const nodeTypes = {
    synth: TrackNode,
    external_audio: TrackNode,
    output_with_panel: OutputNode,
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
    nodes = buildNodes(state);
    edges = buildEdges(state);
  }

  function projectToArrangerState(currentProject: ProjectData, context: EditorContextData | null): ArrangerState {
    const synth_nodes: SynthNodeMap = {};
    const external_nodes: ExternalNodeMap = {};
    const edges: EdgeData[] = [];
    let i = 0;

    for (const track of Object.values(currentProject.tracks ?? {}) as TrackData[]) {
      const trackId = track.id;
      const nodeData = {
        id: trackId,
        type: track.type === "synth" ? "synth" : "external_audio",
        label: track.name || trackId,
        provider_id: "default",
        volume: track.gain ?? 1,
        muted: track.mute || false,
        solo: track.solo || false,
        isActive: context?.track_id === trackId,
        position: track.ui_state?.arranger_position ?? { x: 50, y: i * 160 + 30 },
      };

      if (track.type === "external_audio") {
        external_nodes[trackId] = {
          id: nodeData.id,
          type: nodeData.type,
          label: nodeData.label,
          volume: nodeData.volume,
          muted: nodeData.muted,
          solo: nodeData.solo,
          position: nodeData.position,
        };
      } else {
        synth_nodes[trackId] = {
          ...nodeData,
          note_count: (Object.values(track.segments ?? {}) as SegmentData[]).reduce(
            (count, segment) => count + (segment.notes?.length ?? 0),
            0
          ),
        };
      }

      edges.push({
        id: `e_${trackId}_output`,
        source: trackId,
        target: "output"
      });
      i++;
    }

    return {
      output_node: { id: "output", label: "Master Output", volume: 1.0, muted: false, position: { x: 400, y: 80 } },
      synth_nodes,
      external_nodes,
      edges
    };
  }

  $effect(() => {
    if (payload) {
      syncState(payload as ArrangerState);
    }
  });

  onMount(() => {
    const unsubNodes = bridge.handleEvent("arranger_nodes_available", ({ nodes: defs }: any) => {
      arrangerStepDefs = defs;
    });
    const unsubProject = bridge.handleEvent("project_load", (payload: ProjectData) => {
      project = payload;
    });
    const unsubContext = bridge.handleEvent("editor_context", (payload: EditorContextData) => {
      editorContext = payload;
    });
    const unsubStateUpdated = bridge.handleEvent("state_updated", (state: ArrangerState) => {
      syncState(state);
    });
    const unsubMix = bridge.handleEvent("mix_result", (result: any) => {
      console.log("Mix result:", result);
    });
    const unsubExport = bridge.handleEvent("export_result", (result: any) => {
      console.log("Export result:", result);
    });

    return () => {
      unsubNodes();
      unsubProject();
      unsubContext();
      unsubStateUpdated();
      unsubMix();
      unsubExport();
    };
  });

  $effect(() => {
    if (project) {
      syncState(projectToArrangerState(project, editorContext));
    }
  });

  function addNode(stepDef: any) {
    // This function will dispatch an add_node event for Arranger generic nodes
    bridge.pushEvent("add_arranger_node", { stepDef });
  }

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

  function handleNodeClick({ node }: { node: Node }) {
    if (node.id === "output") return;
    focusTrack(node.id);
  }

  function focusTrack(trackId: string) {
    if (editorContext?.track_id === trackId && editorContext?.scope === "track") return;

    requestEditorContextChange({
      track_id: trackId,
      scope: "track",
    });

    bridge.pushEvent("select_track", { track_id: trackId });
  }

  function focusTrackSegment(trackId: string, segmentId: string) {
    if (
      editorContext?.track_id === trackId &&
      editorContext?.segment_id === segmentId &&
      editorContext?.scope === "segment"
    ) {
      return;
    }

    requestEditorContextChange({
      track_id: trackId,
      segment_id: segmentId,
      scope: "segment",
    });

    bridge.pushEvent("focus_segment", { track_id: trackId, segment_id: segmentId });
  }

  function scopeToLabel(scope: EditorScope) {
    switch (scope) {
      case "segment":
        return "Segment Focus";
      case "track_synth":
        return "Track Synth";
      case "project_mix":
        return "Project Mix";
      default:
        return "Track Focus";
    }
  }

  function resolveTimelineMaxTick(currentProject: ProjectData | null) {
    if (!currentProject) return 1920;

    const trackTicks = Object.values(currentProject.tracks ?? {}).flatMap((track) =>
      Object.values(track.segments ?? {}).map((segment) => segmentEndTick(segment))
    );

    return Math.max(1920, ...trackTicks);
  }

  function segmentEndTick(segment: SegmentData) {
    const noteEndTick = Math.max(
      480,
      ...segment.notes.map((note) => (note.start_tick ?? 0) + (note.duration_tick ?? 0))
    );

    return (segment.offset_tick ?? 0) + noteEndTick;
  }

  function buildTimelineRows(currentProject: ProjectData | null, maxTick: number) {
    if (!currentProject) return [];

    return Object.values(currentProject.tracks ?? {}).map((track) => {
      const segments = Object.values(track.segments ?? {})
        .sort((left, right) => (left.offset_tick ?? 0) - (right.offset_tick ?? 0))
        .map((segment) => {
          const durationTick = Math.max(480, segmentEndTick(segment) - (segment.offset_tick ?? 0));

          return {
            id: segment.id,
            name: segment.name || segment.id,
            leftPct: ((segment.offset_tick ?? 0) / maxTick) * 100,
            widthPct: Math.max((durationTick / maxTick) * 100, 6),
          };
        });

      return {
        id: track.id,
        name: track.name,
        isActive: editorContext?.track_id === track.id,
        segments,
      };
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

  function handleDelete({ edges: deletedEdges }: { nodes: Node[]; edges: Edge[] }) {
    for (const edge of deletedEdges) {
      bridge.pushEvent("remove_edge", { id: edge.id });
    }
  }
</script>

<div class="p-4 border border-slate-200 rounded-lg font-sans bg-white">
  <div class="flex items-center justify-between mb-3">
    <div>
      <h3 class="m-0 text-base text-gray-800">Arranger Mixer</h3>
      <div class="text-[11px] text-slate-500 mt-0.5">{scopeLabel}</div>
    </div>
    <div class="flex gap-2">
      {#each arrangerStepDefs as step}
        <button
          class="px-2 py-1 bg-zinc-200 text-zinc-700 hover:text-black hover:bg-zinc-300 rounded text-xs cursor-pointer border border-zinc-300"
          onclick={() => addNode(step)}
        >
          + {step.name}
        </button>
      {/each}
      <button
        class="px-3 py-1 bg-emerald-600 hover:bg-emerald-500 text-white text-xs rounded cursor-pointer border-none font-medium transition-colors"
        onclick={addExternalTrack}
      >
        + Add Audio Track
      </button>
    </div>
  </div>
  <div class="mb-3 border border-slate-200 rounded-lg overflow-hidden bg-slate-50">
    <div class="px-3 py-2 border-b border-slate-200 bg-slate-100 text-[11px] text-slate-500">
      Track Timeline
    </div>
    <div class="px-3 py-2 border-b border-slate-200 bg-white">
      <div class="relative ml-28 h-5">
        {#each Array.from({ length: 5 }) as _, index}
          <div
            class="absolute top-0 bottom-0 border-l border-dashed border-slate-200 text-[10px] text-slate-400"
            style:left={`${index * 25}%`}
          >
            <span class="absolute -top-0.5 left-1">
              {Math.round((timelineMaxTick / 4) * index)}
            </span>
          </div>
        {/each}
      </div>
    </div>
    <div class="divide-y divide-slate-200">
      {#each timelineRows as row}
        <div class="flex items-stretch bg-white">
          <button
            class="w-28 shrink-0 px-3 py-3 text-left text-xs border-r transition-colors cursor-pointer {row.isActive
              ? 'bg-amber-50 border-amber-200 text-amber-900'
              : 'bg-slate-50 border-slate-200 text-slate-600 hover:bg-slate-100'}"
            onclick={() => focusTrack(row.id)}
          >
            {row.name}
          </button>
          <div class="relative flex-1 min-h-16 bg-linear-to-r from-slate-50 to-white">
            {#each Array.from({ length: 4 }) as _, index}
              <div
                class="absolute top-0 bottom-0 border-l border-dashed border-slate-200"
                style:left={`${(index + 1) * 25}%`}
              ></div>
            {/each}

            {#each row.segments as segment}
              <button
                class="absolute top-3 h-10 rounded-md border px-2 text-left text-xs cursor-pointer shadow-sm transition-all overflow-hidden {editorContext?.segment_id === segment.id && row.isActive
                  ? 'bg-amber-200 border-amber-400 text-amber-950 shadow-amber-200/50'
                  : row.isActive
                    ? 'bg-sky-100 border-sky-300 text-sky-950 hover:bg-sky-200'
                    : 'bg-slate-200 border-slate-300 text-slate-700 hover:bg-slate-300'}"
                style={`left: ${segment.leftPct}%; width: ${segment.widthPct}%`}
                onclick={() => focusTrackSegment(row.id, segment.id)}
                title={segment.name}
              >
                <span class="block truncate">{segment.name}</span>
              </button>
            {/each}
          </div>
        </div>
      {/each}
    </div>
  </div>
  <div class="relative rounded overflow-hidden bg-neutral-800 h-125 text-black">
    <SvelteFlow
      bind:nodes
      bind:edges
      {nodeTypes}
      onnodedragstop={handleNodeDragStop}
      onnodeclick={handleNodeClick}
      onconnect={handleConnect}
      ondelete={handleDelete}
      fitView
    >
      <Background />
      <Controls />
    </SvelteFlow>
  </div>
</div>
