<script lang="ts">
  import type {
    EquinoxBridge,
    ProjectData,
    EditorContextData,
    TrackData,
    SegmentData,
    TempoPoint,
  } from "$lib/bridge";
  import PianoRollInner from "./pianoroll/PianoRoll.svelte";
  import { onMount } from "svelte";

  let { bridge }: { bridge: EquinoxBridge } = $props();

  let project = $state<ProjectData | null>(null);
  let editorContext = $state<EditorContextData | null>(null);
  let notes = $state<any[]>([]);
  let tempos = $state<TempoPoint[]>([{ tick: 0, bpm: 120 }]);
  let hydratingNotes = false;

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

  onMount(() => {
    const unsubProject = bridge.handleEvent<ProjectData>("project_load", (payload) => {
      project = payload;
    });
    const unsubContext = bridge.handleEvent<EditorContextData>("editor_context", (payload) => {
      editorContext = payload;
    });

    return () => {
      unsubProject();
      unsubContext();
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
    const timeout = setTimeout(() => {
      bridge.pushEvent("replace_segment_notes", {
        track_id: activeTrack.id,
        segment_id: activeSegment.id,
        notes: currentNotes.map(toBackendNote),
      });
    }, 300);

    return () => clearTimeout(timeout);
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

</script>

<div class="h-full w-full">
  {#if project}
    <div class="h-full w-full flex flex-col">
      <div class="px-3 py-2 border-b border-zinc-800 bg-zinc-950 text-zinc-300 shrink-0">
        <div class="text-sm font-semibold text-zinc-100">{activeTrackName}</div>
        <div class="text-[11px] text-zinc-500 mt-0.5">{activeSegmentName}</div>
      </div>
      <div class="flex-1 min-h-0">
        <PianoRollInner bind:notes bind:tempos />
      </div>
    </div>
  {:else}
    <div class="flex items-center justify-center h-full w-full text-zinc-500">Loading project...</div>
  {/if}
</div>
