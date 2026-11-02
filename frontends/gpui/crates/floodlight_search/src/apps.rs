//! The application catalog: every `.app` bundle under the standard folders,
//! ranked with the core's scorer.

use crate::matcher;
use std::path::{Path, PathBuf};

pub struct App {
    pub name: String,
    pub path: PathBuf,
    lower: Vec<u8>,
}

impl App {
    pub fn new(path: PathBuf) -> Option<Self> {
        let name = path.file_stem()?.to_str()?.to_owned();
        let lower = name.to_ascii_lowercase().into_bytes();
        Some(Self { name, path, lower })
    }
}

/// The folders Spotlight and Launchpad list apps from. `~/Applications` is
/// only included when HOME is set.
pub fn default_roots() -> Vec<PathBuf> {
    let mut roots = vec![PathBuf::from("/Applications"), PathBuf::from("/System/Applications")];
    if let Some(home) = std::env::var_os("HOME") {
        roots.insert(1, PathBuf::from(home).join("Applications"));
    }
    roots
}

/// Two levels is enough for `/Applications/Utilities/*.app` and vendor
/// folders like `/Applications/Microsoft Office/*.app`, without walking into
/// arbitrary trees someone dropped into `/Applications`.
const MAX_DEPTH: usize = 2;

pub fn scan(roots: &[PathBuf]) -> Vec<App> {
    let mut apps = Vec::new();
    for root in roots {
        walk(root, 0, &mut apps);
    }
    apps.sort_by(|a, b| a.lower.cmp(&b.lower).then_with(|| a.path.cmp(&b.path)));
    // The same bundle name in two roots is two apps, but the same path twice
    // (a root listed twice, a symlinked folder) is one.
    apps.dedup_by(|a, b| a.path == b.path);
    apps
}

fn walk(dir: &Path, depth: usize, out: &mut Vec<App>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        let is_dir = entry.file_type().map(|t| t.is_dir() || t.is_symlink()).unwrap_or(false);
        if !is_dir {
            continue;
        }
        if name.ends_with(".app") {
            out.extend(App::new(path));
        } else if depth + 1 < MAX_DEPTH {
            walk(&path, depth + 1, out);
        }
    }
}

/// Every term must match; a hit's score is the sum over terms, ties to the
/// shorter name. Returns indices into `apps`, best first.
pub fn search(apps: &[App], query: &str, limit: usize) -> Vec<usize> {
    let terms: Vec<Vec<u8>> = query
        .split(' ')
        .filter(|t| !t.is_empty())
        .map(|t| t.to_ascii_lowercase().into_bytes())
        .collect();
    if terms.is_empty() {
        return Vec::new();
    }
    let mut scored: Vec<(i32, usize)> = apps
        .iter()
        .enumerate()
        .filter_map(|(i, app)| {
            let mut total = 0;
            for term in &terms {
                total += matcher::score(&app.lower, term, 0)?;
            }
            Some((total, i))
        })
        .collect();
    scored.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then_with(|| apps[a.1].lower.len().cmp(&apps[b.1].lower.len()))
    });
    scored.into_iter().take(limit).map(|(_, i)| i).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn apps(names: &[&str]) -> Vec<App> {
        names
            .iter()
            .filter_map(|n| App::new(PathBuf::from(format!("/Applications/{n}.app"))))
            .collect()
    }

    #[test]
    fn exact_name_ranks_first() {
        let apps = apps(&["Safari Technology Preview", "Safari", "Stocks"]);
        let hits = search(&apps, "safari", 10);
        assert_eq!(apps[hits[0]].name, "Safari");
        assert_eq!(hits.len(), 2);
    }

    #[test]
    fn all_terms_must_match() {
        let apps = apps(&["Visual Studio Code", "Xcode"]);
        let hits = search(&apps, "vis code", 10);
        assert_eq!(hits.len(), 1);
        assert_eq!(apps[hits[0]].name, "Visual Studio Code");
    }

    #[test]
    fn empty_query_lists_nothing() {
        assert!(search(&apps(&["Safari"]), "  ", 10).is_empty());
    }

    #[test]
    fn scan_finds_nested_bundles_but_not_their_contents() {
        let root = std::env::temp_dir().join(format!("fl-gpui-apps-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("Utilities/Terminal.app/Contents/Helper.app")).unwrap();
        std::fs::create_dir_all(root.join("Safari.app")).unwrap();
        std::fs::create_dir_all(root.join("a/b/Deep.app")).unwrap();
        let names: Vec<String> = scan(std::slice::from_ref(&root)).into_iter().map(|a| a.name).collect();
        assert_eq!(names, ["Safari", "Terminal"]);
        let _ = std::fs::remove_dir_all(&root);
    }
}
