//! `FilesystemResolver` semantics. Mirrors
//! `hosts/web/test/node-fs-resolver.test.ts` and
//! `hosts/typescript-parity/test/filesystem-resolver.test.ts`.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::fs;

use tempfile::tempdir;

use sjon_host::{FilesystemResolver, Reference, Resolution, Resolver, Span};

fn ref_no_path(name: &str) -> Reference {
    Reference {
        name: name.to_string(),
        explicit_path: None,
        version: None,
        hash: None,
        span: Span::ZERO,
    }
}

#[test]
fn no_project_file_yields_empty_index() {
    let dir = tempdir().unwrap();
    let (resolver, diags) = FilesystemResolver::build(dir.path(), None);
    assert!(diags.is_empty());
    let res = resolver.resolve(&ref_no_path("shapes"));
    let Resolution::Failure { code, .. } = res else {
        panic!("expected failure")
    };
    assert_eq!(code, "unresolved_plugin");
}

#[test]
fn single_plugin_project_indexes_by_name() {
    let dir = tempdir().unwrap();
    fs::write(
        dir.path().join("shapes.sjon"),
        "(plugin :name shapes :version \"1.0.0\")\n",
    )
    .unwrap();
    let project_file = dir.path().join("sjon-project.sjon");
    fs::write(&project_file, "(project :plugins [\"shapes.sjon\"])\n").unwrap();
    let (resolver, diags) = FilesystemResolver::build(dir.path(), Some(project_file.as_path()));
    assert!(
        diags.is_empty(),
        "unexpected project-load diagnostics: {diags:?}"
    );
    let res = resolver.resolve(&ref_no_path("shapes"));
    let Resolution::Manifest { source, wasm } = res else {
        panic!("expected manifest envelope")
    };
    assert!(source.contains(":name shapes"));
    assert!(wasm.is_none());
}

#[test]
fn duplicate_plugin_names_emit_duplicate_plugin_name() {
    let dir = tempdir().unwrap();
    fs::write(
        dir.path().join("a.sjon"),
        "(plugin :name shapes :version \"1.0.0\")\n",
    )
    .unwrap();
    fs::write(
        dir.path().join("b.sjon"),
        "(plugin :name shapes :version \"1.0.0\")\n",
    )
    .unwrap();
    let project_file = dir.path().join("sjon-project.sjon");
    fs::write(
        &project_file,
        "(project :plugins [\"a.sjon\" \"b.sjon\"])\n",
    )
    .unwrap();
    let (_resolver, diags) = FilesystemResolver::build(dir.path(), Some(project_file.as_path()));
    assert_eq!(diags.len(), 1);
    assert_eq!(diags[0].code, "duplicate_plugin_name");
    assert_eq!(diags[0].path, vec!["project".to_string()]);
}

#[test]
fn missing_manifest_path_emits_invalid_manifest() {
    let dir = tempdir().unwrap();
    let project_file = dir.path().join("sjon-project.sjon");
    fs::write(&project_file, "(project :plugins [\"missing.sjon\"])\n").unwrap();
    let (_resolver, diags) = FilesystemResolver::build(dir.path(), Some(project_file.as_path()));
    assert_eq!(diags.len(), 1);
    assert_eq!(diags[0].code, "invalid_manifest");
    assert!(diags[0].message.contains("missing.sjon"));
}

#[test]
fn explicit_path_bypasses_index() {
    let dir = tempdir().unwrap();
    fs::write(
        dir.path().join("vendored.sjon"),
        "(plugin :name vended :version \"1.0.0\")\n",
    )
    .unwrap();
    let (resolver, _diags) = FilesystemResolver::build(dir.path(), None);
    let reference = Reference {
        name: "vended".to_string(),
        explicit_path: Some("vendored.sjon".to_string()),
        version: None,
        hash: None,
        span: Span::ZERO,
    };
    let res = resolver.resolve(&reference);
    let Resolution::Manifest { source, wasm } = res else {
        panic!("expected manifest envelope")
    };
    assert!(source.contains(":name vended"));
    assert!(wasm.is_none());
}

#[test]
fn explicit_path_missing_file_yields_unresolved_plugin() {
    let dir = tempdir().unwrap();
    let (resolver, _diags) = FilesystemResolver::build(dir.path(), None);
    let reference = Reference {
        name: "x".to_string(),
        explicit_path: Some("definitely-missing.sjon".to_string()),
        version: None,
        hash: None,
        span: Span::ZERO,
    };
    let res = resolver.resolve(&reference);
    let Resolution::Failure { code, .. } = res else {
        panic!("expected failure")
    };
    assert_eq!(code, "unresolved_plugin");
}

#[test]
fn non_project_root_emits_invalid_manifest() {
    let dir = tempdir().unwrap();
    let project_file = dir.path().join("sjon-project.sjon");
    fs::write(&project_file, "(not-project :plugins [])\n").unwrap();
    let (_resolver, diags) = FilesystemResolver::build(dir.path(), Some(project_file.as_path()));
    assert_eq!(diags.len(), 1);
    assert_eq!(diags[0].code, "invalid_manifest");
}

#[test]
fn nested_manifests_directory_is_walked() {
    let dir = tempdir().unwrap();
    fs::create_dir(dir.path().join("manifests")).unwrap();
    fs::write(
        dir.path().join("manifests/shapes.sjon"),
        "(plugin :name shapes :version \"1.0.0\")\n",
    )
    .unwrap();
    let project_file = dir.path().join("sjon-project.sjon");
    fs::write(
        &project_file,
        "(project :plugins [\"./manifests/shapes.sjon\"])\n",
    )
    .unwrap();
    let (resolver, diags) = FilesystemResolver::build(dir.path(), Some(project_file.as_path()));
    assert!(
        diags.is_empty(),
        "unexpected project-load diagnostics: {diags:?}"
    );
    let res = resolver.resolve(&ref_no_path("shapes"));
    assert!(matches!(res, Resolution::Manifest { .. }));
}

// `(plugin-entry …)` — the reference accepts it (`indexOneManifest` in
// `src/FilesystemResolver.zig`); this host rejected it outright until
// 2026-08-12, so a valid project file failed on three of the four hosts.

#[test]
fn plugin_entry_form_indexes_like_a_bare_path_string() {
    let dir = tempdir().unwrap();
    fs::write(
        dir.path().join("shapes.sjon"),
        "(plugin :name shapes :version \"1.0.0\")\n",
    )
    .unwrap();
    let project_file = dir.path().join("sjon-project.sjon");
    fs::write(
        &project_file,
        "(project :plugins [(plugin-entry :path \"shapes.sjon\")])\n",
    )
    .unwrap();
    let (resolver, diags) = FilesystemResolver::build(dir.path(), Some(project_file.as_path()));
    assert!(
        diags.is_empty(),
        "unexpected project-load diagnostics: {diags:?}"
    );
    let Resolution::Manifest { source, .. } = resolver.resolve(&ref_no_path("shapes")) else {
        panic!("expected manifest envelope")
    };
    assert!(source.contains(":name shapes"));
}

/// `:version` / `:hash` are project-level pins the reference keeps for its
/// `pin_disagreement` cross-check — a `FilesystemResolver`-local check
/// (a deliberate parity boundary). Here they must parse
/// without complaint and change nothing.
#[test]
fn plugin_entry_pins_and_reserved_keys_are_accepted_and_inert() {
    let dir = tempdir().unwrap();
    fs::write(
        dir.path().join("shapes.sjon"),
        "(plugin :name shapes :version \"1.0.0\")\n",
    )
    .unwrap();
    let project_file = dir.path().join("sjon-project.sjon");
    fs::write(
        &project_file,
        format!(
            "(project :plugins [(plugin-entry :path \"shapes.sjon\" :version \"9.9.9\" \
             :hash \"sha256-{}\" :optional true :as other)])\n",
            "0".repeat(64)
        ),
    )
    .unwrap();
    let (resolver, diags) = FilesystemResolver::build(dir.path(), Some(project_file.as_path()));
    assert!(
        diags.is_empty(),
        "unexpected project-load diagnostics: {diags:?}"
    );
    assert!(
        matches!(
            resolver.resolve(&ref_no_path("shapes")),
            Resolution::Manifest { .. }
        ),
        "a disagreeing project pin is not this host's check"
    );
}

#[test]
fn plugin_entry_without_path_emits_invalid_manifest() {
    let dir = tempdir().unwrap();
    let project_file = dir.path().join("sjon-project.sjon");
    fs::write(
        &project_file,
        "(project :plugins [(plugin-entry :version \"1.0.0\")])\n",
    )
    .unwrap();
    let (_resolver, diags) = FilesystemResolver::build(dir.path(), Some(project_file.as_path()));
    assert_eq!(diags.len(), 1);
    assert_eq!(diags[0].code, "invalid_manifest");
    assert!(
        diags[0].message.contains("requires a `:path` string"),
        "got: {}",
        diags[0].message
    );
}

#[test]
fn non_plugin_entry_form_names_the_head_it_saw() {
    let dir = tempdir().unwrap();
    let project_file = dir.path().join("sjon-project.sjon");
    fs::write(
        &project_file,
        "(project :plugins [(plugin-entrie :path \"shapes.sjon\")])\n",
    )
    .unwrap();
    let (_resolver, diags) = FilesystemResolver::build(dir.path(), Some(project_file.as_path()));
    assert_eq!(diags.len(), 1);
    assert_eq!(diags[0].code, "invalid_manifest");
    assert!(
        diags[0].message.contains("got `(plugin-entrie …)`"),
        "got: {}",
        diags[0].message
    );
}
