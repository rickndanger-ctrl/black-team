// "Model ready -> offer setup". Whatever flow has just made a model ready (a finished download, a saved server, a chosen file) calls
// `offerSetupAfterModelReady()`. The window then asks the engine for the setup plan and shows the "Set up your agents" card, unless
// the person has already said "Not now" to everything on it. Calling it starts nothing and changes nothing by itself.
export const MODEL_READY_EVENT = 'black-team:model-ready';

export function offerSetupAfterModelReady(target = globalThis.window) {
  target?.dispatchEvent?.(new CustomEvent(MODEL_READY_EVENT));
}

/** Listens for the call above. Returns the function that stops listening. */
export function onModelReady(handler, target = globalThis.window) {
  target?.addEventListener?.(MODEL_READY_EVENT, handler);
  return () => target?.removeEventListener?.(MODEL_READY_EVENT, handler);
}
