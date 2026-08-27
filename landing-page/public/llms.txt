# SJON: a primer for LLM authors

SJON is a schema-constrained data language: an S-expression surface where
every document is validated against a plugin-declared vocabulary, and every
error comes back as a stable, machine-matchable code. You author a document,
validate it, read the diagnostic, repair, and repeat: a loop small models run
cheaply because the errors *are* the instructions.

A document is a sequence of **forms**. A form is `(head :key value …)`:

```sjon
(camera :mode ortho :zoom 2)      ; head `camera`, two kvpairs
(scene :title "intro" :bpm 120)   ; strings quote; symbols and numbers don't
```

## Tokens (the whole surface)

```
(  )          form                 [  ]          vector
:keyword      a name with a leading colon
symbol        a name without one   (case-sensitive: :bpm ≠ :BPM, a ≠ A)
123 -1.25 1e9   number             4b 90deg 50%    number with unit
"…"  """…"""     string (escaped / raw)           true  false  nil
2026-05-22      date               12:34:56.789    time
;  …            line comment       #| … |#         block comment
```

The value kinds are a **closed set of eleven**: nil, boolean, number,
number_with_unit, date, time, string, keyword, symbol, vector, form.

## The keyword-pairing rule (the #1 confusion)

A `:key` pairs with the value that follows it, *unless* that value is itself a
keyword:

```
:k v         → kvpair          (v is any value except a keyword)
:k :other    → :k is a bare positional flag; :other becomes the new pending key
:k           → (at a frame's end) :k is a positional flag
```

A keyword can never be a kvpair's value. To store an enum-like value use a
**symbol** or string: `:projection ortho` (symbol), not `:projection :ortho`
(which silently makes `:projection` a flag).

## Reading a schema

Schemas are ordinary SJON: a `(plugin …)` manifest, often inline in the
document. This one declares a `circle` form and validates the instance below:

```sjon
(plugin :name geo :version "1.0.0"
  (value-kind :name fill-rule :underlying symbol
    :members (member-set :values [nonzero evenodd]))    ; a closed enum
  (form :name circle
    (key :name radius :type number :optional false)     ; required
    (key :name fill :type fill-rule :optional true)))   ; optional, enum-typed

(circle :radius 1 :fill nonzero)
```

`:optional false` ⇒ the key is required. `:type` names a builtin kind or a
declared `value-kind`. A `value-kind` refines a builtin: a closed member set,
a unit, a `(cross-ref :target other-form)` to another form's `:name`, or a
numeric bound.

## Cross-refs: legal values that come from the document

A `(cross-ref …)` slot's legal values are not in the schema; they are
whatever the document declares. Two routes:

```sjon
(cross-ref :target phrase :name-key name)      ; names = each (phrase :name X)'s X
(cross-ref :target shader :provider uniforms :source-key src)
                                               ; names = what the `uniforms`
                                               ; provider extracts from each
                                               ; (shader :src "…") string
```

On both, a miss is `not_cross_ref` and the message names the key to look at.
`:name-key` ⇒ add or fix a declaration. `:provider` ⇒ the names are *inside*
the string, so read that string; adding a `:name` registers nothing. A
provider is handed only that string, never the filesystem, network, or clock,
so a name absent from the string cannot be made legal by configuration.

Two codes only the provider route produces, both reported at the source
string and **neither repairable at the reference**:

| Code | Means | Repair |
| --- | --- | --- |
| `cross_ref_extraction_failed` | The provider read the source string and rejected it. | Fix that string. |
| `cross_ref_provider_unavailable` | This host cannot execute the provider. | Nothing in the document; the names go unchecked here. |

Either way the member set is unknown, so references into it are reported as
neither valid nor invalid. Silence there is the design, not a missed check.

## The repair loop

```
1. Write the .sjon document.
2. sjon validate FILE --format=json --no-project
3. diagnostics == [] and exit 0  →  done.
4. Else take the FIRST diagnostic and repair by its `code` and `path`:
     code = what rule broke   (stable across hosts; match on THIS)
     path = where             (form head → key → vector index)
   The `message` is human-facing prose and is NOT stable, so don't parse it.
   When the diagnostic carries `hints`, prefer a hint's `replacement`
   string over guessing: it is the exact text to write at the span.
5. Optionally: sjon explain <code> --format=json   for the rule's meaning.
6. Go to 2. Validate after every change, so an error is caught at the step
   that introduced it instead of compounding across a big rewrite.
```

## Codes you'll hit most

<!-- BEGIN GENERATED: diagnostics -->
| Code | Means | Repair |
| --- | --- | --- |
| `unknown_form` | A form's head name is not declared by any loaded plugin. | Fix the head spelling, or load / qualify the plugin as `plugin/head`. |
| `unknown_key` | Form does not declare this `:keyword` and is not `:open true`. | Use the nearest declared key; on a discriminated form set the discriminant key first. |
| `duplicate_key` | Same `:key` appears twice on the same form. | Remove the duplicate; a key may appear at most once per form. |
| `missing_required_key` | Form omits a `:key :optional false` slot with no default. | Add the required key (additive; do not restructure). |
| `positional_not_allowed` | Form's `:positional` declaration is `none` but a positional child was provided. | Wrap the child under the right key; often a keyword-pairing slip. |
| `wrong_underlying` | Value's structural shape does not match the declared `:underlying`. | Match the declared kind, e.g. drop quotes to turn a string into a number. |
| `not_member` | Closed `(member-set …)` does not include this value. | Use one of the closed set's listed members; do not invent a value. |
| `not_head_member` | Form's head is not in the kind's `(head-set …)` whitelist. | Use a form head the slot's head-set allows. |
| `positional_too_many` | More positional children than a `(head-set …)` ceiling allows: the head's `:max`, or the set's `:max-children`. | Delete the child the diagnostic points at; if the message names a bracketed set, the children are individually fine, so keep one and drop the rest. |
| `positional_missing` | Fewer positional children than a `(head-set …)` floor requires: the head's `:min`, or the set's `:min-children`. | Add a child carrying the named head; if the message names a bracketed set, any one head from it will do. |
| `unit_required` | Number value lacks a unit but the kind requires one. | Add an allowed unit suffix (e.g. `90deg`, not `90`). |
| `unit_not_allowed` | Number value carries a unit but the kind's `:allowed` list rejects it. | Swap the unit for one the slot's allowed list accepts, or drop it. |
| `missing_discriminant_key` | Discriminated form lacks the discriminant key. | Add the discriminant key (e.g. `:kind`) so a variant can be selected. |
| `arity_mismatch` | Expression function called with the wrong number of arguments. | Add or drop arguments to match the function's exact count. |
| `expr_type_mismatch` | Expression argument's type does not satisfy the function's `:params` declaration. | Give the argument the type the function's `:params` declare. |
| `not_cross_ref` | Symbol is not a registered name for the cross-ref's target: no target instance declares (or provides) it. | Spell the referenced name correctly, or declare the missing target. |
| `union_no_branch_matched` | No alternative in a `(union-shape …)` accepted the value. | Rewrite the value to fit one of the alternatives the message lists. |
<!-- END GENERATED: diagnostics -->

## Expression vocabulary (the `core` plugin)

Some slots accept **expressions**: `(fn arg …)` forms that evaluate to a value:

```
arithmetic  + - * / mod              comparison  < <= > >= = !=
logical     and or not               vectors     vec2 vec3 vec4
math        lerp clamp min max abs sign floor ceil round fract
            sqrt pow sin cos tan asin acos atan atan2 radians degrees
smoothing   saturate step smoothstep (WGSL)   vector ops  normalize distance reflect
list ops    nth count                random    hash rand01 rand-range rand-int …
constants   (pi) (tau)   (0-arity)   control   let if cond
binders     map filter any all fold
```

Wrong argument count → `arity_mismatch`; wrong argument type →
`expr_type_mismatch`. Domain errors like `(sqrt -1)` return `NaN`, not an error
code, since expressions stay total over `f64`.
