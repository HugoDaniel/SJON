# Where the landing page is lacking

Read of: Hero, prose cards (01/02/03), Pipeline, ParenFold, Snippet, LessonOutline, RepoLinks, index.astro. Pure observation — not a plan to execute.

## Show vs tell — the biggest gap

The page **describes** SJON's distinguishing features in prose; it doesn't **demonstrate** any of them.

- **Diagnostics**: the prose says diagnostic spans are preserved across every entrypoint. None shown. A broken snippet next to its rendered diagnostic would be the strongest single piece of proof on the page — exactly the kind of thing nobody else in the config-language space is doing well.
- **Safe expressions / second layer**: /01 mentions "a parenthesised form whose head is in the expression vocabulary becomes a safe expression rather than data." The hero snippet only shows data forms. No expression in a value position, no `:zoom (lerp …)`, nothing. The headline pitch ("two layers, one front-end") is asserted but never visible.
- **Units**: `4b`, `90deg`, `50%`, `250ms` are namechecked in prose. Not in any snippet. The "preserved through every tool, never silently coerced" claim has no demonstration.
- **Plugins**: the recent feat: plugin DSL extensions — cross-refs, stdlib, exclusive-groups, LSP — is the most interesting work in the repo right now and the landing page doesn't surface any of it. No plugin manifest snippet, no "what a plugin looks like."
- **"Live tutorial"**: hero CTA promises an editor pane with diagnostics streaming from real WASM. No screenshot, no inline mini-playground, no GIF. Big delta between promise and proof.

## Hero specifically

- Tagline buries the lede ("Tiny embeddable Zig package: deterministic S-expression data, optional safe expressions, comptime plugins. Convertible to JSON.") The interesting half-sentence is "two layers parsed by one front-end" from /01 — that belongs in the hero, not paragraph six.
- ParenFold is a one-shot fade. Pretty, but it answers "what does it look like?" not "why would I use it?" A second layer of the animation that swaps the data form for an expression-bearing variant would do double duty.
- CTA is "Start the tutorial." There's no secondary CTA for someone who just wants to skim — no "see the spec," no "see a real plugin," no "see diagnostics." A scanner has one door.

## Architecture section

The Pipeline SVG sells the shape but not the **value**. "One front-end. Six tools." is mechanically true; the payoff line is missing — *this is why your editor experience matches the validator matches the printer matches the binary IR.* The diagram is the most explanatory artifact on the page and it carries the least pitch.

## Prose cards

Three cards, each ~paragraph-dense. No scannable digest — no five-bullet "in 30 seconds" callout, no comparison table (vs JSON, vs EDN, vs Dhall), no "you'd choose this over X when…" framing. Someone scrolling a phone has to commit to reading prose to find out whether SJON is for them.

## Stability / status signal

The page reads polished — coral, dingbats, calm cream paper — which sets reader expectations of "ready to adopt." Memory says SJON is local-dev only with no API stability promise. The page should signal that somewhere visible (a chip, a banner, a one-line note in the footer) so the polish doesn't write a check the project isn't trying to cash.

## Footer / closing

Footer is a coral 2-px stripe and not much else. Missing: license, author, "what to read next" if the user didn't take the tutorial CTA. The page ends instead of closing.

## Mobile

`.prose` at `< 600px` drops to `padding: var(--space-3) var(--space-3)` — which removes the `calc(--card-stripes-h + …)` top clearance. The `/01` kicker and h2 will sit on top of the three stripes at narrow widths. Worth a glance in DevTools at 375px.

## Smaller things

- No diagnostic example, no plugin manifest example, no expression example — see "show vs tell" above; calling out separately because each is a single snippet.
- RepoLinks lists seven docs in flat order. No grouping (start-here / spec / internals). For a first-time visitor that's a wall.
- The dingbat dividers between sections are charming but they appear at every section break. Three of them in a row reads as ornament for ornament's sake; the page would breathe more with one between major movements (intro → architecture, architecture → tutorial) and none between the three /01 /02 /03 cards which already feel like one movement.
- No favicon / OG image audit done in this pass.
