---
expects: duplicate_key
---
# Task: give the scene a title

Schema: `(scene :title <string>)`.

`attempt-1.sjon` sets `:title` twice, a common artifact of editing
by appending rather than replacing. The diagnostic is
`code = duplicate_key`, `path = [scene, title]`. A key may appear at
most once per form. `attempt-2.sjon` keeps the intended value and
drops the other.
