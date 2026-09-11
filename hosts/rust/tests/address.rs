//! `SjonHost::address_of_span` over wasmtime. The Rust and Web hosts read
//! one payload out of one export, so these assertions are the same
//! assertions as `hosts/web/test/address.test.ts`, on the same fixture,
//! down to the byte offsets.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::PathBuf;

use sjon_host::{Address, PathStep, SjonHost};

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

#[test]
fn the_fixture_is_the_asks_byte_for_byte() {
    assert_eq!(FIXTURE.len(), 247);
    assert_eq!(FIXTURE.find("0.4"), Some(153));
    assert_eq!(FIXTURE.find("\"ol"), Some(222));
}

#[test]
fn the_literal_is_root_one_value_zero() {
    let mut host = SjonHost::load(&wasm_path(), None).expect("load sjon.wasm");
    let got = host
        .address_of_span(FIXTURE, 153, 156)
        .expect("address_of_span")
        .expect("the 0.4 is inside a root");
    assert_eq!(
        got,
        Address {
            root: 1,
            path: vec![PathStep::Key("value".to_owned()), PathStep::Index(0)],
            span: (153, 156),
            kind: "number".to_owned(),
        }
    );
}

#[test]
fn a_span_inside_no_root_is_none() {
    let mut host = SjonHost::load(&wasm_path(), None).expect("load sjon.wasm");
    let between = u32::try_from(FIXTURE.find("(param").expect("a param root")).unwrap();
    assert_eq!(
        host.address_of_span(FIXTURE, between - 1, between - 1)
            .expect("address_of_span"),
        None
    );
    assert_eq!(
        host.address_of_span(FIXTURE, 10_000, 10_000)
            .expect("address_of_span"),
        None
    );
}

#[test]
fn the_second_param_reports_root_two() {
    let mut host = SjonHost::load(&wasm_path(), None).expect("load sjon.wasm");
    let at = u32::try_from(FIXTURE.find("0.25").expect("the pace literal")).unwrap();
    let got = host
        .address_of_span(FIXTURE, at, at + 4)
        .expect("address_of_span")
        .expect("inside the third root");
    assert_eq!(got.root, 2);
    assert_eq!(got.path, vec![PathStep::Key("value".to_owned())]);
    assert_eq!(got.kind, "number");
}

#[test]
fn a_document_that_does_not_parse_still_has_addresses() {
    let mut host = SjonHost::load(&wasm_path(), None).expect("load sjon.wasm");
    let broken = FIXTURE.replace("日本\")", "日本)");
    let at = u32::try_from(broken.find("0.4").expect("the heat literal")).unwrap();
    let got = host
        .address_of_span(&broken, at, at + 3)
        .expect("address_of_span")
        .expect("a recovery still addresses");
    assert_eq!(
        got.path,
        vec![PathStep::Key("value".to_owned()), PathStep::Index(0)]
    );
}
