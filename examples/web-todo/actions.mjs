// Action creators. Each returns a JSON-encoded `Edit` action that
// `SjonEncoder.applyEdit` can apply against the current state. The
// shapes are pinned by `src/Edit.zig`'s `//!` header:
//   * `path` is a JSON array of integer/string steps from the root.
//   * Integer steps index positional children (kvpairs skipped).
//   * String steps key into kvpairs.
//   * `value` is decoded through `Json.fromJson` — canonical tagging
//     applies (`{$sym}` for symbols, `{$kw}` for keywords, etc.).

export const addTodo = (id, text) => ({
    op: "insert_positional",
    path: ["items"],
    value: { $form: "todo", id, text, done: false },
});

export const bumpNextId = (next) => ({
    op: "set_keyword",
    path: [],
    key: "next-id",
    value: next,
});

export const toggleTodo = (index, done) => ({
    op: "set_keyword",
    path: ["items", index],
    key: "done",
    value: done,
});

export const removeTodo = (index) => ({
    op: "remove_positional",
    path: ["items"],
    index,
});

// `:filter` is a symbol-typed slot (the `filter-kw` value-kind in
// todo-app.sjon), so the canonical edit value is `{$sym}` — not
// `{$kw}`, even though it reads like a keyword in the UI.
export const setFilter = (name) => ({
    op: "set_keyword",
    path: [],
    key: "filter",
    value: { $sym: name },
});
