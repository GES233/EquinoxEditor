import type { EditorContextData } from "$lib/bridge";

const BEFORE_CONTEXT_CHANGE_EVENT = "equinox:before-editor-context-change";

type BeforeContextChangeDetail = Partial<EditorContextData>;

export function requestEditorContextChange(detail: BeforeContextChangeDetail) {
  if (typeof window === "undefined") return;

  window.dispatchEvent(
    new CustomEvent<BeforeContextChangeDetail>(BEFORE_CONTEXT_CHANGE_EVENT, {
      detail,
    })
  );
}

export function subscribeBeforeEditorContextChange(
  handler: (detail: BeforeContextChangeDetail) => void
) {
  if (typeof window === "undefined") return () => {};

  const listener = (event: Event) => {
    const customEvent = event as CustomEvent<BeforeContextChangeDetail>;
    handler(customEvent.detail);
  };

  window.addEventListener(BEFORE_CONTEXT_CHANGE_EVENT, listener);

  return () => {
    window.removeEventListener(BEFORE_CONTEXT_CHANGE_EVENT, listener);
  };
}
