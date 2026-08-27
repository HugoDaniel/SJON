/**
 * The one keyboard collision between the editor and the site around it.
 *
 * Starlight's search modal listens for `(meta|ctrl)+k` on `window`. On macOS
 * CodeMirror's `standardKeymap` binds `Ctrl-k` to `deleteToLineEnd` — the
 * emacs-style bindings are registered `mac:`-only — and a key CodeMirror
 * handled gets `preventDefault` but not `stopPropagation`, so it goes on
 * bubbling. One `Ctrl-K` in the editor therefore both deletes to end of line
 * *and* opens search.
 *
 * Split out from `codemirror-setup.ts` so it can be tested: that module
 * reaches `@sjon/highlight`, which imports its TextMate grammar as JSON, and a
 * bare `node --test` cannot load that without an import attribute.
 */

/** Nothing imported here on purpose — see the module header. */
export interface ModifierKeyEvent {
  ctrlKey: boolean;
  metaKey: boolean;
  key: string;
}

/**
 * Does this keydown belong to the editor rather than to the site's search?
 *
 * `isMac` is the whole condition. Off macOS nothing in the editor claims
 * `Ctrl-k`, and it is the shortcut Starlight advertises there, so swallowing
 * it would take away the only keyboard route to search rather than fix
 * anything. `Cmd-K` is never swallowed on either platform: search from
 * anywhere is right, and no editor binding wants it.
 */
export function isEditorSearchShortcutCollision(event: ModifierKeyEvent, isMac: boolean): boolean {
  return isMac && event.ctrlKey && !event.metaKey && event.key === 'k';
}

/**
 * Matches `@codemirror/view`'s own check, which is what decides the keymap.
 *
 * `navigator.platform` is deprecated, and it is still the right thing to read
 * here: agreeing with CodeMirror is the entire job, and CodeMirror reads that
 * property. `userAgentData.platform` would be the modern answer and is
 * Chromium-only, so it would disagree with the keymap in Safari and Firefox —
 * on exactly the platform this is about. Read through an index so the
 * deprecation does not show up as a diagnostic on a deliberate choice.
 */
export function onMacPlatform(): boolean {
  if (typeof navigator === 'undefined') return false;
  const platform = (navigator as unknown as Record<string, unknown>)['platform'];
  return typeof platform === 'string' && /Mac|iPhone|iPad|iPod/.test(platform);
}
