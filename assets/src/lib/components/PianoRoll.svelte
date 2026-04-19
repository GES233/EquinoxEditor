<script lang="ts">
  import type {
    EquinoxBridge,
    ProjectData,
    EditorContextData,
    TrackData,
    SegmentData,
    TempoPoint,
    EditorScope,
  } from "$lib/bridge";
  import {
    requestEditorContextChange,
    subscribeBeforeEditorContextChange,
  } from "$lib/editor_context";
  import PianoRollInner from "./pianoroll/PianoRoll.svelte";
  import { onMount } from "svelte";

  let { bridge }: { bridge: EquinoxBridge } = $props();

  let project = $state<ProjectData | null>(null);
  let editorContext = $state<EditorContextData | null>(null);
  let notes = $state<any[]>([]);
  let tempos = $state<TempoPoint[]>([{ tick: 0, bpm: 120 }]);
  let hydratingNotes = false;
  let pendingSaveTimer: ReturnType<typeof setTimeout> | null = null;
  let pendingSavePayload:
    | { track_id: string; segment_id: string; notes: Record<string, any>[] }
    | null = null;

  let activeTrack = $derived.by((): TrackData | null => {
    const trackId = editorContext?.track_id;
    if (!project || !trackId) return null;
    return project.tracks[trackId] ?? null;
  });

  let activeSegment = $derived.by((): SegmentData | null => {
    const segmentId = editorContext?.segment_id;
    if (!activeTrack || !segmentId) return null;
    return activeTrack.segments[segmentId] ?? null;
  });

  let activeTrackName = $derived(activeTrack?.name ?? "No Track Selected");
  let activeSegmentName = $derived(activeSegment?.name ?? "No Segment Selected");
  let availableSegments = $derived.by((): SegmentData[] => {
    if (!activeTrack) return [];
    return Object.values(activeTrack.segments ?? {}).sort((left, right) =>
      (left.offset_tick ?? 0) - (right.offset_tick ?? 0)
    );
  });
  let scopeLabel = $derived(scopeToLabel(editorContext?.scope ?? "track"));

  onMount(() => {
    const unsubProject = bridge.handleEvent<ProjectData>("project_load", (payload) => {
      project = payload;
    });
    const unsubContext = bridge.handleEvent<EditorContextData>("editor_context", (payload) => {
      editorContext = payload;
    });
    const unsubBeforeContextChange = subscribeBeforeEditorContextChange(() => {
      flushPendingSave();
    });

    return () => {
      flushPendingSave();
      unsubProject();
      unsubContext();
      unsubBeforeContextChange();
    };
  });

  $effect(() => {
    tempos = project?.tempo_map?.length ? project.tempo_map : [{ tick: 0, bpm: 120 }];
  });

  $effect(() => {
    hydratingNotes = true;
    notes = activeSegment ? toPianoRollNotes(activeSegment) : [];
  });

  $effect(() => {
    if (hydratingNotes) {
      hydratingNotes = false;
      return;
    }
    if (!activeTrack || !activeSegment) return;

    const currentNotes = $state.snapshot(notes);
    schedulePendingSave(activeTrack.id, activeSegment.id, currentNotes.map(toBackendNote));
  });

  function toPianoRollNotes(segment: SegmentData) {
    return segment.notes.map((note) => ({
      ...note,
      length_tick: note.duration_tick,
      pitch: note.key,
    }));
  }

  function toBackendNote(note: Record<string, any>) {
    return {
      id: note.id,
      start_tick: note.start_tick ?? 0,
      duration_tick: note.duration_tick ?? note.length_tick ?? 480,
      key: note.key ?? note.pitch ?? 60,
      lyric: note.lyric ?? "la",
      phoneme: note.phoneme ?? null,
      extra: note.extra ?? {},
    };
  }

  function focusSegment(segmentId: string) {
    if (!activeTrack) return;
    if (editorContext?.segment_id === segmentId) return;

    requestEditorContextChange({
      track_id: activeTrack.id,
      segment_id: segmentId,
      scope: "segment",
    });

    bridge.pushEvent("focus_segment", {
      track_id: activeTrack.id,
      segment_id: segmentId,
    });
  }

  function schedulePendingSave(trackId: string, segmentId: string, currentNotes: Record<string, any>[]) {
    pendingSavePayload = {
      track_id: trackId,
      segment_id: segmentId,
      notes: currentNotes,
    };

    if (pendingSaveTimer) {
      clearTimeout(pendingSaveTimer);
    }

    pendingSaveTimer = setTimeout(() => {
      flushPendingSave();
    }, 300);
  }

  function flushPendingSave() {
    if (pendingSaveTimer) {
      clearTimeout(pendingSaveTimer);
      pendingSaveTimer = null;
    }

    if (!pendingSavePayload) return;

    bridge.pushEvent("replace_segment_notes", pendingSavePayload);
    pendingSavePayload = null;
  }

  function scopeToLabel(scope: EditorScope) {
    switch (scope) {
      case "segment":
        return "Segment Edit";
      case "track_synth":
        return "Track Synth Context";
      case "project_mix":
        return "Project Mix Context";
      default:
        return "Track Focus";
    }
  }

</script>

<div class="h-full w-full">
  {#if project}
    <div class="h-full w-full flex flex-col">
      <div class="px-3 py-2 border-b border-zinc-800 bg-zinc-950 text-zinc-300 shrink-0">
        <div class="text-sm font-semibold text-zinc-100">{activeTrackName}</div>
        <div class="text-[11px] text-zinc-500 mt-0.5">{activeSegmentName}</div>
        <div class="text-[11px] text-zinc-600 mt-0.5">{scopeLabel}</div>
        {#if availableSegments.length > 0}
          <div class="flex flex-wrap gap-2 mt-2">
            {#each availableSegments as segment}
              <button
                class="px-2 py-1 rounded text-[11px] cursor-pointer border transition-colors {editorContext?.segment_id === segment.id
                  ? 'bg-amber-100 border-amber-300 text-amber-900'
                  : 'bg-zinc-900 border-zinc-700 text-zinc-400 hover:bg-zinc-800'}"
                onclick={() => focusSegment(segment.id)}
              >
                {segment.name || segment.id}
              </button>
            {/each}
          </div>
        {/if}
      </div>
      <div class="flex-1 min-h-0">
        <PianoRollInner bind:notes bind:tempos />
      </div>
    </div>
  {:else}
    <div class="flex items-center justify-center h-full w-full text-zinc-500">Loading project...</div>
  {/if}
</div>
