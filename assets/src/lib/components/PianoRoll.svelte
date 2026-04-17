<script lang="ts">
  import type { EquinoxBridge, ProjectData, TrackData, SegmentData, NoteData, TempoPoint } from "$lib/bridge";
  import PianoRollInner from "./pianoroll/PianoRoll.svelte";
  import { onMount } from "svelte";

  let { bridge }: { bridge: EquinoxBridge } = $props();

  let project = $state<ProjectData | null>(null);
  
  // For the prototype Piano Roll, we just visualize the first segment of the first track
  // In a real multi-track DAW, we would have a TrackSelector or Arranger deciding the active context
  let activeTrackId = $derived(project ? Object.keys(project.tracks)[0] : null);
  let activeSegmentId = $derived(project && activeTrackId ? Object.keys(project.tracks[activeTrackId].segments)[0] : null);
  
  let notes = $state<any[]>([]);
  let tempos = $state<TempoPoint[]>([{tick: 0, bpm: 120}]);

  onMount(() => {
    // Listen for the initial or updated project state from the backend
    const unsub = bridge.handleEvent<ProjectData>("project_load", (payload) => {
      console.log("Received Project Data:", payload);
      project = payload;
      
      // Map tempos
      if (project.tempo_map && project.tempo_map.length > 0) {
        tempos = project.tempo_map;
      }

      // Map notes from the first segment
      if (activeTrackId && activeSegmentId) {
        const activeSegment = project.tracks[activeTrackId].segments[activeSegmentId];
        // Translate Equinox.Domain.Note shape (start_tick, duration_tick, key) 
        // to PianoRoll's expected shape if necessary. Our component already uses start_tick, length_tick internally
        notes = activeSegment.notes.map(n => ({
          ...n,
          length_tick: n.duration_tick, // the UI expects length_tick right now, but we can migrate
          pitch: n.key                  // the UI expects pitch right now
        }));
      }
    });

    return unsub;
  });

  // We need to carefully sync edits back without creating an infinite loop.
  // For now, we'll listen for note changes from the PianoRollInner using callback events
  // instead of a blanket $effect on `notes`, because the user interaction triggers atomic events (add, move, delete).
  //
  // NOTE: PianoRollInner currently uses $bindable for notes, which makes fine-grained events tricky.
  // We'll leave the blanket $effect for now but map it to our new events or refactor PianoRollInner later.
  
  $effect(() => {
    if (notes.length > 0 && activeSegmentId) {
      // In a real app we'd diff the notes or fire specific events on drag-end.
      // For this PoC, we can just send the whole segment update or mimic the old behaviour
      bridge.pushEvent("update_note", { 
        segment_id: activeSegmentId, 
        note: $state.snapshot(notes[0]) // just a dummy payload for now
      });
    }
  });

</script>

<div class="h-full w-full">
  {#if project}
    <PianoRollInner bind:notes bind:tempos />
  {:else}
    <div class="flex items-center justify-center h-full w-full text-zinc-500">Loading project...</div>
  {/if}
</div>