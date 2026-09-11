//! `SjonHost::node_table` over wasmtime. The Rust and Web hosts read one
//! payload out of one export, so this is `hosts/web/test/address.test.ts`'s
//! table assertions, on the same fixture, down to the byte offsets. The
//! two hosts agreeing on one payload is the whole point of mirroring it.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::PathBuf;

use sjon_host::{NodeRow, NodeTable, PathStep, SjonHost};

fn wasm_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../zig-out/bin/sjon.wasm");
    p
}

/// Ask 25's fixture: four roots, a nested expression, one line past ASCII.
const FIXTURE: &str = concat!(
    "; The spike's fixture: one declaration over time, one plain literal,\n",
    "; and a title in more than ASCII.\n",
    "(use-plugin \"spike\")\n",
    "\n",
    "(param :name heat :value (* 0.4 (sin (* time 0.2))))\n",
    "(param :name pace :value 0.25)\n",
    "(title :text \"olá — ☀️ 日本\")",
);

/// The §11.2 path of `row`, walked up the table's `parent` links — the
/// port of the web host's `pathOfRow`, and the thing a consumer of this
/// table actually does with it.
fn path_of(table: &NodeTable, row: &NodeRow) -> Vec<PathStep> {
    let mut steps: Vec<PathStep> = Vec::new();
    let mut at = Some(row);
    while let Some(cur) = at {
        if let Some(seg) = &cur.seg {
            steps.push(seg.clone());
        }
        at = usize::try_from(cur.parent).ok().map(|p| &table.nodes[p]);
    }
    steps.reverse();
    steps
}

#[test]
fn the_0_4_row_matches_the_web_host_byte_for_byte() {
    let mut host = SjonHost::load(&wasm_path(), None).expect("load sjon.wasm");
    let table = host.node_table(FIXTURE).expect("node_table");
    assert!(table.diagnostics.is_empty());

    let row = table
        .nodes
        .iter()
        .find(|n| n.span == (153, 156))
        .expect("a row for the 0.4");
    assert_eq!(row.kind, "number");
    assert_eq!(row.root, 1);
    assert_eq!(row.seg, Some(PathStep::Index(0)));
    assert_eq!(row.head_span, None);
    assert_eq!(row.key_span, None);
    assert_eq!(
        path_of(&table, row),
        vec![PathStep::Key("value".to_owned()), PathStep::Index(0)]
    );

    // Which is the answer the point export gives for the same range.
    let point = host
        .address_of_span(FIXTURE, 153, 156)
        .expect("address_of_span")
        .expect("inside a root");
    assert_eq!(point.path, path_of(&table, row));
    assert_eq!(point.root, row.root);
    assert_eq!(point.span, row.span);
    assert_eq!(point.kind, row.kind);
}

#[test]
fn rows_are_pre_order_and_no_row_is_a_kvpair() {
    let mut host = SjonHost::load(&wasm_path(), None).expect("load sjon.wasm");
    let table = host.node_table(FIXTURE).expect("node_table");

    let mut roots = 0u32;
    for (i, row) in table.nodes.iter().enumerate() {
        assert_eq!(usize::try_from(row.i).unwrap(), i);
        if row.parent < 0 {
            assert_eq!(row.seg, None);
            assert_eq!(row.root, roots);
            roots += 1;
        } else {
            let parent = usize::try_from(row.parent).expect("a non-root parent index");
            assert!(parent < i, "row {i} parent {parent}");
            assert!(row.seg.is_some());
        }
        // §11.2 addresses a pair's value, never the pair.
        assert_ne!(row.kind, "kvpair");
        assert_eq!(row.kind == "form", row.head_span.is_some());
    }
    assert_eq!(roots, 4);
}

#[test]
fn a_key_span_rides_on_the_values_row() {
    let mut host = SjonHost::load(&wasm_path(), None).expect("load sjon.wasm");
    let table = host.node_table(FIXTURE).expect("node_table");

    let heat = table
        .nodes
        .iter()
        .find(|n| n.seg == Some(PathStep::Key("name".to_owned())) && n.root == 1)
        .expect("the heat symbol");
    assert_eq!(&FIXTURE[heat.span.0 as usize..heat.span.1 as usize], "heat");
    let key = heat.key_span.expect("a key span on the value's row");
    assert_eq!(&FIXTURE[key.0 as usize..key.1 as usize], ":name");
}

#[test]
fn the_titles_span_is_utf8_bytes_not_utf16_units() {
    let mut host = SjonHost::load(&wasm_path(), None).expect("load sjon.wasm");
    let table = host.node_table(FIXTURE).expect("node_table");

    let title = table
        .nodes
        .iter()
        .find(|n| n.kind == "string" && n.seg == Some(PathStep::Key("text".to_owned())))
        .expect("the title string");
    // Transcript 7: [222, 246) in bytes; a UTF-16 reading gives [222, 235).
    assert_eq!(title.span, (222, 246));
    assert_eq!(
        &FIXTURE[title.span.0 as usize..title.span.1 as usize],
        "\"olá — ☀️ 日本\""
    );
}

#[test]
fn a_document_that_does_not_parse_returns_rows_and_diagnostics() {
    let mut host = SjonHost::load(&wasm_path(), None).expect("load sjon.wasm");
    let broken = FIXTURE.replace("日本\")", "日本)");
    let table = host.node_table(&broken).expect("node_table");
    assert!(!table.nodes.is_empty());
    assert_eq!(table.diagnostics.len(), 2);
}
