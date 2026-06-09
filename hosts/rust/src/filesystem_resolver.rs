//! Default fs-backed resolver. Mirrors
//! `hosts/web/createNodeFsResolver.ts` and
//! `hosts/typescript-parity/src/FilesystemResolver.ts`:
//!
//!   1. Read `sjon-project.sjon`, walk `(project :plugins […])`.
//!   2. For each entry, read the manifest, parse top-level
//!      `(plugin :name <symbol|string> …)` to extract the name, index by name.
//!   3. Duplicate `:name` → `duplicate_plugin_name` diagnostic.
//!   4. `(use-plugin "name")` → index lookup; explicit `:path` → direct file read.
//!
//! `build` returns `(Self, Vec<HostDiagnostic>)`. Caller forwards the
//! diagnostics through `HostOptions.project_diagnostics`; `SjonHost`
//! prepends them so they land under `phase: Manifest` exactly like
//! Zig's native pipeline drains its own resolver's project diagnostics.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::diagnostic::{HostDiagnostic, Phase, Severity, Span};
use crate::resolver::{Reference, Resolution, Resolver};
use crate::sjon_subset::{Node, find_kvpair, parse_single_form};

#[derive(Debug)]
struct ManifestEntry {
    manifest_path: PathBuf,
    manifest_source: String,
}

/// Default project-file-aware `Resolver` that walks
/// `sjon-project.sjon`, indexes every listed manifest under
/// `:plugins`, and resolves `(use-plugin :name X)` requests by name.
/// Pair with `SjonHost::load`; project-load diagnostics are returned
/// alongside the resolver from `build`.
pub struct FilesystemResolver {
    project_root: PathBuf,
    has_project_file: bool,
    project_file_display: String,
    name_index: HashMap<String, ManifestEntry>,
}

impl FilesystemResolver {
    /// Build the resolver against `project_root`. `project_file` is the
    /// `sjon-project.sjon` path (or `None` to skip indexing). Returns
    /// the resolver paired with any project-load diagnostics.
    pub fn build(
        project_root: impl Into<PathBuf>,
        project_file: Option<&Path>,
    ) -> (Self, Vec<HostDiagnostic>) {
        let project_root = project_root.into();
        let mut name_index: HashMap<String, ManifestEntry> = HashMap::new();
        let mut diagnostics: Vec<HostDiagnostic> = Vec::new();
        let mut has_project_file = false;
        let mut project_file_display = String::new();

        if let Some(pf) = project_file {
            has_project_file = true;
            project_file_display = pf.display().to_string();
            load_project_file(&project_root, pf, &mut name_index, &mut diagnostics);
        }

        (
            FilesystemResolver {
                project_root,
                has_project_file,
                project_file_display,
                name_index,
            },
            diagnostics,
        )
    }
}

impl Resolver for FilesystemResolver {
    fn resolve(&self, reference: &Reference) -> Resolution {
        if let Some(rel) = reference.explicit_path.as_deref() {
            let abs = resolve_against_root(&self.project_root, rel);
            return match std::fs::read_to_string(&abs) {
                Ok(source) => Resolution::Manifest {
                    source,
                    wasm: try_read_sibling_wasm(&abs),
                },
                Err(err) => Resolution::Failure {
                    code: "unresolved_plugin".to_string(),
                    detail: format!("explicit :path `{}` unreadable: {}", abs.display(), err),
                },
            };
        }
        if let Some(entry) = self.name_index.get(&reference.name) {
            return Resolution::Manifest {
                source: entry.manifest_source.clone(),
                wasm: try_read_sibling_wasm(&entry.manifest_path),
            };
        }
        if !self.has_project_file {
            return Resolution::Failure {
                code: "unresolved_plugin".to_string(),
                detail: format!(
                    "no plugin named `{}` (no project file in `{}`)",
                    reference.name,
                    self.project_root.display(),
                ),
            };
        }
        Resolution::Failure {
            code: "unresolved_plugin".to_string(),
            detail: format!(
                "no plugin named `{}` in `{}`",
                reference.name, self.project_file_display
            ),
        }
    }
}

fn load_project_file(
    project_root: &Path,
    project_file: &Path,
    name_index: &mut HashMap<String, ManifestEntry>,
    diagnostics: &mut Vec<HostDiagnostic>,
) {
    let source = match std::fs::read_to_string(project_file) {
        Ok(s) => s,
        Err(err) => {
            diagnostics.push(project_diag(
                "invalid_manifest",
                format!(
                    "could not read project file `{}`: {}",
                    project_file.display(),
                    err
                ),
            ));
            return;
        }
    };
    let parsed = match parse_single_form(&source) {
        Ok(opt) => opt,
        Err(err) => {
            diagnostics.push(project_diag(
                "invalid_manifest",
                format!(
                    "project file `{}` failed to parse: {}",
                    project_file.display(),
                    err
                ),
            ));
            return;
        }
    };
    let Some(Node::Form { head, children }) = parsed else {
        return; // empty file is fine
    };
    if head != "project" {
        diagnostics.push(project_diag(
            "invalid_manifest",
            format!("expected (project …) at top level of sjon-project.sjon, got `{head}`"),
        ));
        return;
    }
    let Some(plugins) = find_kvpair(&children, "plugins") else {
        return;
    };
    let Node::Vector { elements } = plugins else {
        diagnostics.push(project_diag(
            "invalid_manifest",
            "`:plugins` must be a vector of manifest path strings".to_string(),
        ));
        return;
    };
    for elem in elements {
        index_one_manifest(project_root, elem, name_index, diagnostics);
    }
}

fn index_one_manifest(
    project_root: &Path,
    elem: &Node,
    name_index: &mut HashMap<String, ManifestEntry>,
    diagnostics: &mut Vec<HostDiagnostic>,
) {
    let Node::String(rel) = elem else {
        diagnostics.push(project_diag(
            "invalid_manifest",
            "`:plugins` entries must be path strings".to_string(),
        ));
        return;
    };
    let manifest_path = resolve_against_root(project_root, rel);
    let manifest_source = match std::fs::read_to_string(&manifest_path) {
        Ok(s) => s,
        Err(err) => {
            diagnostics.push(project_diag(
                "invalid_manifest",
                format!(
                    "manifest at `{}` unreadable: {}",
                    manifest_path.display(),
                    err
                ),
            ));
            return;
        }
    };
    let parsed = match parse_single_form(&manifest_source) {
        Ok(opt) => opt,
        Err(err) => {
            diagnostics.push(project_diag(
                "invalid_manifest",
                format!(
                    "manifest at `{}` failed to parse: {}",
                    manifest_path.display(),
                    err
                ),
            ));
            return;
        }
    };
    let Some(Node::Form { head, children }) = parsed else {
        diagnostics.push(project_diag(
            "invalid_manifest",
            format!(
                "manifest at `{}` is not a (plugin …) form",
                manifest_path.display()
            ),
        ));
        return;
    };
    if head != "plugin" {
        diagnostics.push(project_diag(
            "invalid_manifest",
            format!(
                "manifest at `{}` is not a (plugin …) form",
                manifest_path.display()
            ),
        ));
        return;
    }
    let name = if let Some(Node::Symbol(s) | Node::String(s)) = find_kvpair(&children, "name") {
        s.clone()
    } else {
        diagnostics.push(project_diag(
            "invalid_manifest",
            format!("manifest at `{}` is missing :name", manifest_path.display()),
        ));
        return;
    };
    if let Some(existing) = name_index.get(&name) {
        diagnostics.push(project_diag(
            "duplicate_plugin_name",
            format!(
                "plugin `:name {}` already declared by `{}`; refusing last-wins",
                name,
                existing.manifest_path.display()
            ),
        ));
        return;
    }
    name_index.insert(
        name,
        ManifestEntry {
            manifest_path,
            manifest_source,
        },
    );
}

/// Look for an executable-plugin sidecar wasm next to `manifest_path`.
/// Pairing is by file stem — `manifests/double.sjon` pairs with
/// `manifests/double.wasm`. Absent or unreadable files yield `None`;
/// errors are silent because a manifest without a sidecar wasm is the
/// declarative-only path and not a load failure.
fn try_read_sibling_wasm(manifest_path: &Path) -> Option<Vec<u8>> {
    let wasm_path = manifest_path.with_extension("wasm");
    std::fs::read(&wasm_path).ok()
}

fn resolve_against_root(root: &Path, rel: &str) -> PathBuf {
    let p = Path::new(rel);
    if p.is_absolute() {
        p.to_path_buf()
    } else {
        root.join(p)
    }
}

fn project_diag(code: &str, message: String) -> HostDiagnostic {
    HostDiagnostic {
        phase: Phase::Manifest,
        code: code.to_string(),
        severity: Severity::Err,
        message,
        span: Span::ZERO,
        path: vec!["project".to_string()],
        declaration_span: None,
    }
}
