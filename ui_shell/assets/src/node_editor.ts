import NodeEditor from "$lib/components/NodeEditor.svelte";
import { createSvelteHook } from "$lib/bridge";

export const NodeEditorHook = createSvelteHook(NodeEditor);