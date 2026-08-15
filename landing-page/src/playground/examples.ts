/**
 * Curated playground examples — one per feature the server is worth showing off
 * for. Plain data, no imports: `scripts/check-examples.mjs` loads this module
 * under `node --experimental-strip-types` and runs every entry through the real
 * `sjon-lsp.wasm`, so nothing here may reach for a DOM or an Astro global.
 *
 * **These are authored for the playground, not shared with the marketing
 * carousel or the `examples/plugins/` fixtures.** Both were scouted as seeds
 * and both were rejected on evidence: `ExampleCarousel.astro`'s snippets are
 * static syntax showcases for a host app that owns its own plugins, so every
 * one of them lights the playground up with `unknown_form`; the fixture pairs
 * under `examples/plugins/` do validate clean, but their prose is written for
 * fixture maintainers (JSON-Schema `$ref` layout, `.d.ts` emit) and reads as
 * noise to a visitor. Different audiences, different samples — the anti-rot
 * guarantee comes from `check-examples`, not from a shared string.
 *
 * Every entry either validates clean or declares the diagnostic codes it means
 * to provoke; `check-examples` enforces both directions and fails the build on
 * drift, so a schema-language change cannot quietly break the front door.
 */

export interface PlaygroundExample {
  /** Stable id — also the value the toolbar `<select>` carries. */
  id: string;
  /** Dropdown label. */
  title: string;
  /** One line under the picker: what this example is here to show. */
  blurb: string;
  /** The document pane's text. */
  doc: string;
  /** Schema panes, in tab order. */
  schemas: string[];
  /**
   * Diagnostic codes this example exists to provoke. Omitted means "must be
   * clean". Present means the example is a *demo* of those diagnostics and
   * must keep producing exactly them.
   */
  expectDiagnostics?: readonly string[];
}

const WELCOME_DOC = `; Welcome to the SJON playground.
; Parse, validate, and evaluate all run locally in your tab —
; diagnostics in the gutter, values under the editor, as you type.

; Math expressions, with the core plugin pre-allowed.
(+ 2 3)
(* 2 (+ 3 4))
(smoothstep 0 1 0.5)

; Numbers carry units wherever they are stored;
; expressions compute on the bare number.
(let [bpm   130
      delay 4b
      angle 90deg
      t     0.5
      r     (lerp 0 1 t)]
  (vec3 r angle bpm))

; Vectors and conditionals.
(if (> 5 3)
  [1 2 3 4]
  [0 0 0])
`;

const SHAPES_SCHEMA = `; A schema declares the forms and keys a document may use.
; Open a second tab with "+ schema" to load more than one.

(plugin :name shapes :version "1.0.0"
  (form :name circle
    :description "A disc. Both keys carry defaults."
    (key :name radius :type number :default 32)
    (key :name fill :type string :default "black" :optional true)))
`;

const DEFAULTS_DOC = `; The schema tab beside this one gives :radius and :fill defaults.
; Keys you leave out are drawn as ghost text — the effective document,
; without rewriting the one you typed.

(circle)

(circle :radius 8)

(circle :radius 8 :fill "tomato")
`;

const DIAGNOSTICS_DOC = `; Every mistake below is deliberate — this example is here to show what
; the validator says. Hover a squiggle for the explanation. Where the
; server can name the repair, the gutter offers to apply it.

(circle :radiuss 8)      ; a typo — this one has a quick fix

(circle :radius "wide")  ; the right key, the wrong type

(square :side 4)         ; no such form in the schema
`;

const GRAPH_SCHEMA = `; \`:from\` and \`:to\` are declared as cross-refs, so the validator checks
; that each one names a \`(node …)\` that exists in the document.

(plugin :name graph :version "1.0.0"
  (value-kind :name node-ref
    :description "Cross-ref to a (node …) declared elsewhere in the document."
    :underlying symbol
    :cross-ref (cross-ref :target node :name-key id))

  (form :name node
    :description "A named vertex."
    (key :name id :type symbol)
    (key :name label :type string :optional true))

  (form :name edge
    :description "A directed edge between two nodes."
    (key :name from :type node-ref)
    (key :name to :type node-ref)))
`;

const GRAPH_DOC = `; Put the cursor on a node name and the other end lights up.
; Rename one — or point an edge somewhere that does not exist — and
; the validator follows the reference for you.

(node :id intro :label "Opening")
(node :id verse :label "Verse")
(node :id coda  :label "Coda")

(edge :from intro :to verse)
(edge :from verse :to coda)
`;

const TRACKS_SCHEMA = `; \`track\` is discriminated on :kind. Each variant accepts a different
; set of keys, so the value of :kind decides what else is legal.

(plugin :name tracks :version "1.0.0"
  (value-kind :name kind-tag
    :underlying symbol
    :members (member-set :values [kick bass]))

  (form :name track
    :description "One instrument lane."
    :discriminant kind
    (key :name kind :type kind-tag)
    (variant :when kick
      (key :name step :type number :optional true))
    (variant :when bass
      (key :name sequence :type any :optional true))))
`;

const TRACKS_DOC = `; :step belongs to the kick variant, :sequence to the bass variant.
; Swap a :kind and the keys under it stop being legal.

(track :kind kick :step 4)

(track :kind bass :sequence [1 0 1 0])
`;

const THEME_SCHEMA = `; Half a schema: \`palette\` holds forms that live in the other tab.

(plugin :name theme :version "1.0.0"
  (value-kind :name swatch
    :description "Either a colour or a gradient — both declared in \`swatches\`."
    :underlying form
    :heads (head-set :names [color gradient]))

  (form :name palette
    :description "Named palette holding one swatch per slot."
    (key :name name :type symbol)
    (key :name primary :type swatch)
    (key :name accent :type swatch :optional true)))
`;

const SWATCHES_SCHEMA = `; The other half. Neither schema validates this document alone.

(plugin :name swatches :version "1.0.0"
  (form :name color
    :description "A solid colour."
    (key :name hex :type string))

  (form :name gradient
    :description "A two-stop linear gradient."
    (key :name from :type string)
    (key :name to :type string)
    (key :name angle :type number :optional true)))
`;

const PALETTE_DOC = `; This document needs both schema tabs. \`palette\` comes from \`theme\`;
; the (color …) and (gradient …) inside it come from \`swatches\`.
; Close either tab and the document stops validating.

(palette :name brand
  :primary (color :hex "#1f2937")
  :accent  (gradient :from "#9333ea" :to "#06b6d4" :angle 45))
`;

export const PLAYGROUND_EXAMPLES: readonly PlaygroundExample[] = [
  {
    id: 'welcome',
    title: 'Expressions',
    blurb: 'Arithmetic, bindings, and units — evaluated in your tab as you type.',
    doc: WELCOME_DOC,
    schemas: [],
  },
  {
    id: 'defaults',
    title: 'Defaults',
    blurb: 'Keys the schema defaults appear as ghost text where you omitted them.',
    doc: DEFAULTS_DOC,
    schemas: [SHAPES_SCHEMA],
  },
  {
    id: 'diagnostics',
    title: 'Diagnostics',
    blurb: 'Deliberate mistakes: what the validator says, and where it offers a fix.',
    doc: DIAGNOSTICS_DOC,
    schemas: [SHAPES_SCHEMA],
    expectDiagnostics: ['unknown_key', 'unknown_form', 'wrong_underlying'],
  },
  {
    id: 'cross-refs',
    title: 'Cross-references',
    blurb: 'Names checked across the document — go to definition, find references.',
    doc: GRAPH_DOC,
    schemas: [GRAPH_SCHEMA],
  },
  {
    id: 'variants',
    title: 'Variants',
    blurb: 'One key discriminates the form; the variant it selects decides the rest.',
    doc: TRACKS_DOC,
    schemas: [TRACKS_SCHEMA],
  },
  {
    id: 'two-schemas',
    title: 'Two schemas',
    blurb: 'A document validated against a pair of plugins that reference each other.',
    doc: PALETTE_DOC,
    schemas: [THEME_SCHEMA, SWATCHES_SCHEMA],
  },
];

/** The example the playground opens with when the URL carries no state. */
export const DEFAULT_EXAMPLE: PlaygroundExample = PLAYGROUND_EXAMPLES[0]!;
