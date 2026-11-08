//! Search for the GPUI frontend: files through the Zig core, applications
//! from a folder scan, both ranked by the same scorer. Nothing here knows
//! about GPUI, so it builds and tests on any host the core builds on.

pub mod apps;
pub mod core;
pub mod matcher;

use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    App,
    File,
    Folder,
}

#[derive(Clone, Debug)]
pub struct Row {
    pub kind: Kind,
    pub title: String,
    pub subtitle: String,
    pub path: PathBuf,
}

/// Apps come first and are capped, the order Spotlight uses: a launcher query
/// that names an app almost always wants the app.
pub const APP_ROWS: usize = 6;
/// The issue caps a publication at 80 rows; a panel shows ten, so 40 keeps
/// scrolling honest without laying out text nobody reaches.
pub const MAX_ROWS: usize = 40;

#[derive(Default)]
pub struct Searcher {
    pub apps: Arc<Vec<apps::App>>,
    pub files: Option<Arc<core::Index>>,
}

impl Searcher {
    pub fn search(&self, query: &str) -> Vec<Row> {
        let query = query.trim();
        if query.is_empty() {
            return Vec::new();
        }
        let mut rows: Vec<Row> = apps::search(&self.apps, query, APP_ROWS)
            .into_iter()
            .map(|i| {
                let app = &self.apps[i];
                Row {
                    kind: Kind::App,
                    title: app.name.clone(),
                    subtitle: parent_label(&app.path),
                    path: app.path.clone(),
                }
            })
            .collect();
        if let Some(index) = &self.files {
            let mut hits = [core::Hit::default(); MAX_ROWS];
            let n = index.search(query, &mut hits[..MAX_ROWS - rows.len()]);
            for hit in &hits[..n] {
                let Some(path) = index.path(hit.id) else { continue };
                // An app bundle is already listed above from the catalog.
                if path.extension().is_some_and(|e| e == "app") {
                    continue;
                }
                let kind = if index.is_dir(hit.id) { Kind::Folder } else { Kind::File };
                let title = path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                rows.push(Row {
                    kind,
                    title,
                    subtitle: parent_label(&path),
                    path,
                });
            }
        }
        rows
    }
}

/// The parent folder with the home directory folded to `~`, the way Finder
/// and Spotlight show locations.
fn parent_label(path: &std::path::Path) -> String {
    let parent = path
        .parent()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() && parent.starts_with(&home) => format!("~{}", &parent[home.len()..]),
        _ => parent,
    }
}
