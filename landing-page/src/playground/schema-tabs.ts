/**
 * Schema-tabs controller for the playground.
 *
 * Owns the schema panes that live alongside the always-present
 * "document" tab: each schema is a `(plugin …)` manifest edited in its
 * own CodeMirror instance. Valid manifests are composed into the live
 * schema (server-side, via `sjon/setSchemas`) so the document tab starts
 * enforcing the forms they declare.
 *
 * The controller manages tab activation (a roving-tabindex ARIA tablist
 * spanning the document tab + every schema tab), add/remove, and a
 * coalesced `setSchemas` sync that relabels each tab from the parsed
 * plugin `:name`. It reuses `createPlaygroundEditor` per pane.
 */

import { createPlaygroundEditor } from './codemirror-setup';
import type { PlaygroundEditor } from './codemirror-setup';
import { registerSchemaView, unregisterSchemaView, syncSchemas } from './lsp-integration';
import type { SchemaInput } from './lsp-types';

/** Starter manifest for a fresh schema pane — demonstrates the `task`
 *  form the document tab will then know about. */
export const SCHEMA_TEMPLATE = `; A schema is a (plugin …) manifest. Forms declared here become known,
; closed-by-default forms in the document tab.
(plugin :name my-schema :version "0.1.0"

  (form :name task
    (key :name title :type string)
    (key :name done  :type boolean :optional true)))
`;

interface SchemaTab {
  id: string;
  num: number;
  uri: string;
  editor: PlaygroundEditor;
  tabEl: HTMLElement;
  labelEl: HTMLElement;
  pane: HTMLElement;
}

export interface SchemaTabsController {
  addSchema: (initialText?: string) => void;
  /** Swap the whole schema set — used when loading a curated example, which
   *  may need fewer panes than are currently open, or none. */
  replaceSchemas: (texts: readonly string[]) => void;
  getSchemaTexts: () => string[];
  /** Push the current schema set to the server (used once the LSP is
   *  ready, after boot replays deep-linked schemas). */
  resync: () => Promise<void>;
  destroy: () => void;
}

export interface SchemaTabsOpts {
  /** Fired on any change that should be reflected in the URL hash: a
   *  schema text edit, or a tab added/removed. */
  onStateChange: () => void;
}

const SYNC_DEBOUNCE_MS = 150;

export function createSchemaTabs(root: HTMLElement, opts: SchemaTabsOpts): SchemaTabsController {
  const tablist = root.querySelector<HTMLElement>('[data-pg-tablist]');
  const panes = root.querySelector<HTMLElement>('[data-pg-panes]');
  const addBtn = root.querySelector<HTMLElement>('[data-pg-add]');
  const docTab = root.querySelector<HTMLElement>('[data-pg-tab="document"]');
  const docPane = root.querySelector<HTMLElement>('[data-pg-pane="document"]');
  if (!tablist || !panes || !addBtn || !docTab || !docPane) {
    throw new Error('createSchemaTabs: missing tab shell elements');
  }

  const tabs: SchemaTab[] = [];
  let counter = 0;
  let activeId = 'document';
  let syncTimer: ReturnType<typeof setTimeout> | null = null;

  function allTabEls(): HTMLElement[] {
    return Array.from(tablist!.querySelectorAll<HTMLElement>('[role="tab"]'));
  }

  function activate(id: string): void {
    activeId = id;
    for (const el of allTabEls()) {
      const selected = el.dataset['pgTab'] === id;
      el.setAttribute('aria-selected', selected ? 'true' : 'false');
      el.tabIndex = selected ? 0 : -1;
    }
    docPane!.hidden = id !== 'document';
    for (const t of tabs) t.pane.hidden = t.id !== id;
  }

  function focusTab(id: string): void {
    for (const el of allTabEls()) {
      if (el.dataset['pgTab'] === id) {
        el.focus();
        return;
      }
    }
  }

  function wireTab(el: HTMLElement): void {
    el.addEventListener('click', () => {
      const id = el.dataset['pgTab'];
      if (id) activate(id);
    });
    el.addEventListener('keydown', (event: KeyboardEvent) => {
      const id = el.dataset['pgTab'];
      if (!id) return;
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        activate(id);
        return;
      }
      if ((event.key === 'Delete' || event.key === 'Backspace') && id !== 'document') {
        event.preventDefault();
        removeSchema(id);
        return;
      }
      const els = allTabEls();
      const index = els.indexOf(el);
      if (index < 0) return;
      let nextIndex = index;
      if (event.key === 'ArrowRight') nextIndex = (index + 1) % els.length;
      else if (event.key === 'ArrowLeft') nextIndex = (index - 1 + els.length) % els.length;
      else if (event.key === 'Home') nextIndex = 0;
      else if (event.key === 'End') nextIndex = els.length - 1;
      else return;
      event.preventDefault();
      const next = els[nextIndex];
      if (!next) return;
      next.focus();
      const nextId = next.dataset['pgTab'];
      if (nextId) activate(nextId);
    });
  }

  function scheduleSync(): void {
    if (syncTimer !== null) clearTimeout(syncTimer);
    syncTimer = setTimeout(() => {
      syncTimer = null;
      void runSync();
    }, SYNC_DEBOUNCE_MS);
  }

  async function runSync(): Promise<void> {
    const inputs: SchemaInput[] = tabs.map((t) => ({
      uri: t.uri,
      text: t.editor.getValue(),
    }));
    const reports = await syncSchemas(inputs);
    for (const report of reports) {
      const tab = tabs.find((t) => t.uri === report.uri);
      if (!tab) continue;
      const label = report.name.length > 0 ? report.name : `schema ${tab.num}`;
      tab.labelEl.textContent = label;
    }
  }

  function removeSchema(id: string): void {
    const i = tabs.findIndex((t) => t.id === id);
    if (i < 0) return;
    const tab = tabs[i];
    if (!tab) return;
    unregisterSchemaView(tab.uri);
    tab.editor.destroy();
    tab.tabEl.remove();
    tab.pane.remove();
    tabs.splice(i, 1);
    if (activeId === id) {
      activate('document');
      focusTab('document');
    }
    opts.onStateChange();
    scheduleSync();
  }

  /** Tear every pane down and rebuild from `texts`. Both the server sync and
   *  the hash write are debounced downstream, so the per-tab calls the loop
   *  makes coalesce into one of each.
   *
   *  Ends on the document tab: `addSchema` activates each pane it creates,
   *  which is right when the visitor asked for a new schema and wrong here —
   *  loading an example would otherwise open on its *schema* rather than the
   *  document the example is about. */
  function replaceSchemas(texts: readonly string[]): void {
    for (const tab of [...tabs]) removeSchema(tab.id);
    for (const text of texts) addSchema(text);
    activate('document');
  }

  function addSchema(initialText: string = SCHEMA_TEMPLATE): void {
    counter += 1;
    const num = counter;
    const id = `schema-${num}`;
    const uri = `inmemory://schema/${num}.sjon`;

    const pane = document.createElement('div');
    pane.className = 'pg-pane';
    pane.id = `pg-pane-${id}`;
    pane.setAttribute('role', 'tabpanel');
    pane.setAttribute('aria-labelledby', `pg-tab-${id}`);
    pane.dataset['pgPane'] = id;
    pane.hidden = true;
    const mount = document.createElement('div');
    pane.appendChild(mount);
    panes!.appendChild(pane);

    const editor = createPlaygroundEditor(mount, {
      initialCode: initialText,
      onChange: () => {
        scheduleSync();
        opts.onStateChange();
      },
    });

    const tabEl = document.createElement('div');
    tabEl.className = 'pg-tab pg-tab--schema';
    tabEl.id = `pg-tab-${id}`;
    tabEl.setAttribute('role', 'tab');
    tabEl.setAttribute('aria-selected', 'false');
    tabEl.setAttribute('aria-controls', `pg-pane-${id}`);
    tabEl.tabIndex = -1;
    tabEl.dataset['pgTab'] = id;

    const labelEl = document.createElement('span');
    labelEl.className = 'pg-tab__label';
    labelEl.textContent = `schema ${num}`;

    const closeEl = document.createElement('button');
    closeEl.type = 'button';
    closeEl.className = 'pg-tab__close';
    closeEl.setAttribute('aria-label', `Remove schema ${num}`);
    closeEl.tabIndex = -1;
    closeEl.textContent = '×';
    closeEl.addEventListener('click', (event: MouseEvent) => {
      event.stopPropagation();
      removeSchema(id);
    });

    tabEl.append(labelEl, closeEl);
    tablist!.appendChild(tabEl);
    wireTab(tabEl);

    tabs.push({ id, num, uri, editor, tabEl, labelEl, pane });
    registerSchemaView(uri, editor.view);

    activate(id);
    // CodeMirror in a `hidden` pane measures 0px; force a re-measure now
    // that the pane is visible so the gutter/scroller lay out correctly.
    editor.view.requestMeasure();
    editor.view.focus();

    opts.onStateChange();
    scheduleSync();
  }

  function getSchemaTexts(): string[] {
    return tabs.map((t) => t.editor.getValue());
  }

  function destroy(): void {
    if (syncTimer !== null) {
      clearTimeout(syncTimer);
      syncTimer = null;
    }
    for (const t of tabs) t.editor.destroy();
    tabs.length = 0;
  }

  wireTab(docTab);
  addBtn.addEventListener('click', () => addSchema());

  return { addSchema, replaceSchemas, getSchemaTexts, resync: runSync, destroy };
}
