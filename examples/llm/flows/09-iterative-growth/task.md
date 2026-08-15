---
expects: clean
---
# Task: grow a service spec one field at a time, validating each step

This is the **dynamic-spec loop** the pack exists to demonstrate: a
model builds a document incrementally and validates after every
addition, so a mistake is caught at the step that introduced it —
never compounded across a large rewrite.

Schema: `(service :name <string> :port <number> :replicas <number>)`,
`:name` required, the rest optional.

- `step-1.sjon` — `(service :name "api")`. The minimum viable doc.
  Clean.
- `step-2.sjon` — adds `:port 8080`. Clean.
- `step-3.sjon` — adds `:replicas 3`. Clean.

Every step validates with exit 0 and empty `diagnostics`. The point
is the cadence: each `sjon validate … --format=json --no-project`
returns `"diagnostics": []` before the next field is added, so the
loop never carries an unresolved error forward.
