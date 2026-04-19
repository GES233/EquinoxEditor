import PianoRoll from "$lib/components/PianoRoll.svelte";
import { createSvelteHook } from "$lib/bridge";

export const PianoRollHook = createSvelteHook(PianoRoll);