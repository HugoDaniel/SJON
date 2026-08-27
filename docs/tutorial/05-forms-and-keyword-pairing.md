# 05 - Forms and Keyword Pairing

## Goal

Predict exactly when `:keyword value` becomes a kvpair and when the
keyword becomes a positional flag instead, without ever having to run
the parser to find out.

## The Debt Comes Due

Twice now I have written something like "two keywords in a row are two
flags, and Forms and keyword pairing explains why". This is that
lesson. Here is the whole rule, and it fits on one line:

> A kvpair is formed when a keyword is followed by a **non-keyword**
> value. A keyword can never be the value of a kvpair.

That is it. Everything else in this lesson is consequences.

Take the form we have been building and add a projection to it, the way
you would if you had not read [Atoms and intent](03-atoms-and-intent.md):

```sjon
(camera :projection :ortho)
```

You meant `projection = ortho`. Here is what the parser builds:

```
before, in your head:            after, in the tree:

(camera)                         (camera)
  :projection = :ortho             :projection      <- flag, no value
                                   :ortho           <- flag, no value
```

The parser reaches `:projection`, looks at the next value to see whether
it can pair, finds another keyword, and commits `:projection` as a
standalone flag. Then it reaches `:ortho`, finds the closing paren, and
commits that as a flag too. Two children, both flags, and the camera has
no projection set at all.

No error is raised at parse time, because nothing is wrong at parse
time. Two flags is a perfectly ordinary form. What you get instead is a
validation diagnostic saying that `camera` doesn't accept a flag called
`:projection`, and possibly nothing at all if the schema is open. This
is why I have been warning you about it since
[Orientation](01-orientation.md): it is the one mistake in SJON that stays
silent for a while.

## Why It Works That Way

The obvious counter-proposal is to let a keyword be a value, so that
`:projection :ortho` pairs. I chose not to, and the reason is this form:

```sjon
(text "Hello" :bold :italic)
```

Two independent style flags. Under the counter-proposal that parses as
`bold = :italic`, and the text is neither bold nor italic. There is no
way to have both behaviours: either adjacent keywords are two flags, or
adjacent keywords are a pair, and one of those readings has to lose.

I picked the reading that keeps flags composable, because a flag that
silently swallows the next flag is the worse failure. When a slot really
does need a named value, the value gets written as something that is not
a keyword, which is exactly the symbol-versus-string decision from
[Atoms and intent](03-atoms-and-intent.md).

So `(text "Hello" :bold :italic)` is not a gotcha. It is the intended
case, and the gotcha is only the *other* reading of the same shape:
when one of those two keywords was meant to be a value.

## Reading a Form

A form is a head and an ordered list of children:

```sjon
(camera
  :ortho
  :zoom 2
  :pos [0 1])
```

```
(camera)
  |-- :ortho          next value is `:zoom`, a keyword  -> flag
  |-- :zoom 2         next value is `2`, a number       -> kvpair
  `-- :pos [0 1]      next value is a vector            -> kvpair
```

That right-hand column is the whole algorithm. For every keyword, look
at the value immediately after it: another keyword makes it a flag,
anything else makes it a kvpair and consumes that value.

Now the part that catches people who assume the rule stops at atoms.
This tutorial and `examples/basic.sjon` both used to get it wrong, in
the same place. The file contained this line, and
the [Orientation](01-orientation.md) lesson confidently described it
as two positional flags:

```sjon
(stack :mode :overlay
  (shape :sdf :radius 0.5)
  (shape :path :closed true))
```

Run the algorithm honestly. `:mode` is pending, `:overlay` arrives and
is a keyword, so `:mode` commits as a flag and `:overlay` becomes
pending. Now the parser consumes the next value in the frame, and that
value is `(shape :sdf :radius 0.5)`. A form is not a keyword. So it
pairs:

```
what the file claimed:            what the parser built:

(stack)                           (stack)
  :mode      flag                   :mode                    flag
  :overlay   flag                   :overlay (shape :sdf …)  kvpair
  (shape :sdf …)                    (shape :path …)          positional
  (shape :path …)
```

The first shape was swallowed as the value of a key nobody meant to
write, and the stack lost a child. Nothing complained, because nothing
was syntactically wrong. That file now reads `(stack :mode overlay …)`,
which is the repair from [Atoms and intent](03-atoms-and-intent.md), and the
lesson I want you to take is not "watch out for stack" but **the pending
key reaches past the newline for its value.** Line breaks are not
fences. [Your first document](02-first-document.md) said whitespace never shapes
the tree, and this is the sharpest place that bites.

## Three Repairs

```sjon del={1}
(camera :projection :ortho)
```

If the schema expects a symbol from a member set, use a symbol:

```sjon ins={1}
(camera :projection ortho)
```

If the schema expects free text, use a string:

```sjon
(camera :projection "ortho")
```

And if you genuinely need keyword values, put them in a vector:

```sjon
(stack :modes [:mask])
```

Inside a vector, `:mask` is an ordinary keyword value. Vectors have no
kvpairs at all, so there is no pairing rule to trip over and no
ambiguity to resolve. This is the escape hatch, and it costs one pair
of brackets.

## Exercises

Predict the children of each of these before reading the repair.

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

Children: the kvpair `:zoom 2`, then the trailing flag `:ortho`. No
repair needed if `:ortho` was meant as a flag, which in our running
camera it is.

```sjon del={1}
(circle :center [0 0] :radius 1 :fill :evenodd)
```

Children: two kvpairs, then two flags. If `:fill` wants a symbol member
set:

```sjon ins={1}
(circle :center [0 0] :radius 1 :fill evenodd)
```

Repair drill:

```sjon del={1}
(badge :label "ok" :shape :circle)
```

If `:shape` is a slot pinned to a `(circle ...)` or `(rect ...)` form,
then the value is not a name at all, it is a form:

```sjon ins={1}
(badge :label "ok" :shape (circle :center [0 0] :radius 1))
```

## Kvpairs in Expression Heads

One correction to make before you leave, because I stated the rule too
simply above. Data forms pair keys to values as described. Expression
heads such as `(lerp ...)` and `(vec3 ...)` take positional arguments by
default, and some of them opt into a labelled call form in which kvpairs
work differently again. [Safe expressions](07-safe-expressions.md) covers that
contract. The pairing rule in this lesson is unchanged; what changes is
what the head does with the pairs afterwards.

## Mastery Check

- What does `(stack :mode :mask)` parse as?
- How do you write an enum-like value in a kvpair?
- Where can a keyword safely be used as a value?
- Why do forms with no positional children expose keyword-pairing
  mistakes quickly?

Next: [Comments and Strings](06-comments-and-strings.md).
