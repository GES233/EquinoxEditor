<script lang="ts">
  import type { EquinoxBridge } from "$lib/bridge";
  import PianoRollInner from "./pianoroll/PianoRoll.svelte";

  let { bridge }: { bridge: EquinoxBridge } = $props();

  // In the future, notes will be fetched from Elixir via bridge or LiveView hooks
  let notes = $state([]);
  let tempos = $state([{tick: 0, bpm: 120}]);

  // Sync edits back to Phoenix when notes change
  $effect(() => {
    // Only send if we have notes (to avoid wiping out backend state on initial empty load if any)
    if (notes.length > 0) {
      // bridge.pushEvent("update_notes", { notes: $state.snapshot(notes) });
    }
  });

</script>

<div class="h-full w-full">
  <PianoRollInner bind:notes bind:tempos />
</div>