---
expects: wrong_underlying
---
# Task: set the scene tempo to 120 BPM

Schema: `(scene :bpm <number>)`.

`attempt-1.sjon` quotes the value — `:bpm "120"` — so the slot gets a
string where the schema wants a number. The diagnostic is
`code = wrong_underlying`, `path = [scene, bpm]`; the message names
both the expected and actual kind. `attempt-2.sjon` drops the quotes:
`:bpm 120`. (This is the "underlying kind is wrong" case — distinct
from a unit-suffix mismatch, which reports `unit_required` /
`unit_not_allowed` instead.)
