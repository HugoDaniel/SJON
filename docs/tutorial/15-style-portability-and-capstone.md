# 15 - Style, Portability, and Capstone

## Goal

Combine authoring habits into one complete document: readable structure,
correct value kinds, useful comments, raw string payloads, safe
expressions, and portable head choices.

## Mental Model

Good SJON is predictable before validation:

- Put keys before positional children unless there is a strong local
  reason not to.
- Use symbols for schema-resolved options.
- Use strings for labels and opaque text.
- Use keyword flags only when they are really flags.
- Use raw strings for large text payloads.
- Keep expressions small and local.
- Rely on plugin defaults only when the omitted value is genuinely the
  value you want.
- Qualify domain-specific heads when a document must travel across
  multiple host setups.
- Leave core expression heads bare.

Bare heads are fine for one known host:

```sjon
(circle :center [0 0] :radius 1)
```

Qualified heads are more portable when plugin collisions are possible:

```sjon
(shapes/circle :center [0 0] :radius 1)
```

## Worked Example

A local-authoring version:

```sjon
(scene :title "capstone" :author "ada" :draft false
  :notes """review pass:
- border group frames the canvas
- focal mark pulses from host-supplied t
"""
  (canvas :w 320 :h 240 :bg "black"
    ;; frame
    (group :name "border"
      (rect :origin [0 0] :size [320 4])
      (rect :origin [0 236] :size [320 4]))

    ;; focal mark
    (badge :label "pulse"
      :shape (circle :center [160 120]
                     :radius (let [phase (clamp t 0 1)]
                               (lerp 12 32 phase))
                     :fill evenodd))))
```

A more portable version qualifies domain heads:

```sjon
(shapes/scene :title "capstone" :author "ada" :draft false
  :notes """review pass:
- border group frames the canvas
- focal mark pulses from host-supplied t
"""
  (shapes/canvas :w 320 :h 240 :bg "black"
    (shapes/group :name "border"
      (shapes/rect :origin [0 0] :size [320 4])
      (shapes/rect :origin [0 236] :size [320 4]))

    (shapes/badge :label "pulse"
      :shape (shapes/circle :center [160 120]
                            :radius (let [phase (clamp t 0 1)]
                                      (lerp 12 32 phase))
                            :fill evenodd))))
```

Core expression heads remain bare: `let`, `lerp`, and `clamp`.

## Exercises

Style pass:

Rewrite this for readability without changing meaning:

```sjon
(scene (canvas (circle :radius 1 :center [0 0]) :bg "black" :h 240 :w 320) :title "demo")
```

One clean answer:

```sjon
(scene :title "demo"
  (canvas :w 320 :h 240 :bg "black"
    (circle :center [0 0] :radius 1)))
```

Portability pass:

Qualify domain heads but leave core expression heads bare:

```sjon
(scene :title "demo"
  (canvas :w (+ 300 20) :h 240
    (circle :center [160 120] :radius (clamp 32 0 64))))
```

Portable form:

```sjon
(shapes/scene :title "demo"
  (shapes/canvas :w (+ 300 20) :h 240
    (shapes/circle :center [160 120] :radius (clamp 32 0 64))))
```

Raw payload pass:

Add a raw string payload to a scene metadata slot or a host-specific
form. Keep the opener on the same line as the first payload byte if you
do not want a leading newline.

## Capstone

Author a complete SJON document that includes:

- One top-level scene-like root.
- At least three nested levels.
- One vector of points or repeated point-like values.
- One string label and one raw string payload.
- One boolean or nil value.
- One safe expression using `lerp` or `clamp`.
- One `let`, `if`, or `cond`.
- One form-valued slot such as a badge shape.
- Comments that explain intent, not syntax.

Then intentionally break six things:

1. Misspell one form head.
2. Misspell one key.
3. Duplicate one key.
4. Use `:keyword` where a symbol value is expected.
5. Use a disallowed form head in a head-set slot.
6. Give a typed expression function an obviously wrong literal argument.

Repair each break by naming the likely diagnostic category before
changing the source.

## Mastery Check

- Can you explain why every keyword in your capstone is either a key or
  a deliberate flag?
- Can you identify every symbol and say what schema or binding resolves
  it?
- Can you move from local bare heads to portable qualified heads?
- Can you break and repair your own document using diagnostic codes?

Back to the [course map](README.md).
