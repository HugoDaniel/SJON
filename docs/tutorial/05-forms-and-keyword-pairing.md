# 05 - Forms and Keyword Pairing

## Goal

Understand forms as constructor calls and predict exactly when a
`:keyword value` pair forms a kvpair versus when a keyword becomes a
positional flag.

## Mental Model

A form has a head and an ordered list of children:

```sjon
(camera
  :ortho
  :zoom 2
  :pos [0 1])
```

The children are:

- `:ortho` - a positional flag.
- `:zoom 2` - a kvpair.
- `:pos [0 1]` - a kvpair.

The key rule:

```sjon
:key value
```

pairs only when `value` is a non-keyword value. A keyword can never be
the value of a kvpair.

This means:

```sjon
(stack :mode :mask)
```

does not mean `mode = :mask`. It means two positional flags:
`:mode` and `:mask`.

Two flags side by side isn't always a mistake. When both keywords are
meant as independent toggles, that same parse is exactly the intent:

```sjon
(text "Hello" :bold :italic)
```

Children: `:bold` flag, `:italic` flag. Both styles apply. The gotcha
bites only when one of those keywords was meant to be a *value*.

That separation is deliberate. Adjacent flags should remain unambiguous:
if one keyword could become another keyword's kvpair value, the two
flags in `(text "Hello" :bold :italic)` would turn into
`bold = :italic`. When a slot needs a value instead, use a symbol,
string, or container shape that the schema documents.

## Worked Example

Broken:

```sjon
(camera :projection :ortho)
```

What the parser sees:

- `:projection` cannot pair with `:ortho`.
- `:projection` is committed as a positional flag.
- `:ortho` is also a positional flag when the form closes.

Repair when the schema expects a symbol:

```sjon
(camera :projection ortho)
```

Repair when the schema expects free-form text:

```sjon
(camera :projection "ortho")
```

Repair when you truly need keywords as values by wrapping them in a
vector:

```sjon
(stack :modes [:mask])
```

Inside the vector, `:mask` is a keyword value because vectors do not
have kvpairs.

## Exercises

Predict the children before reading the repairs:

```sjon
(stack :mode :overlay)
```

Children: `:mode` flag, `:overlay` flag. Repair as a symbol enum:

```sjon
(stack :mode overlay)
```

```sjon
(camera :zoom 2 :ortho)
```

Children: kvpair `:zoom 2`, then trailing flag `:ortho`. No repair is
needed if `:ortho` is meant to be a flag.

```sjon
(circle :center [0 0] :radius 1 :fill :evenodd)
```

If `:fill` expects a symbol member set, repair with a symbol:

```sjon
(circle :center [0 0] :radius 1 :fill evenodd)
```

Repair drill:

```sjon
(badge :label "ok" :shape :circle)
```

If `:shape` expects a form slot pinned to `(circle ...)` or `(rect ...)`,
repair it with a form value:

```sjon
(badge :label "ok" :shape (circle :center [0 0] :radius 1))
```

## Kvpairs in expression heads

Data forms pair keys to values; expression heads (`(lerp …)`, `(vec3 …)`)
take positional arguments by default. Some expression functions opt into
a labeled call form so kvpairs work there too — see
[Safe Expressions](07-safe-expressions.md) for the contract.

## Mastery Check

- What does `(stack :mode :mask)` parse as?
- How do you write an enum-like value in a kvpair?
- Where can a keyword safely be used as a value?
- Why do forms with no positional children expose keyword-pairing
  mistakes quickly?

Next: [Comments and Strings](06-comments-and-strings.md).
