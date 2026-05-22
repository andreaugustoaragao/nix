//! `group_by_directory`: aggregate paths by their parent directory.
//!
//! Turns a flat list of N paths into a directory-summarized map. The wrapper
//! decides how to render it (flat list, drill-down with thresholds, etc.).
//! This primitive owns the grouping invariant, not the formatting.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// Group paths by their immediate parent directory.
///
/// Returns a `BTreeMap` (parent_dir → basenames in input order). Paths with
/// no parent (`Path::parent()` returns `None` or empty) are bucketed under
/// `PathBuf::new()` so callers can present root-level files distinctly.
///
/// The returned map is sorted by parent path because `BTreeMap` is sorted by
/// key — that gives consumers a stable, deterministic order without an
/// extra pass.
pub fn group_by_directory<P: AsRef<Path>>(paths: &[P]) -> BTreeMap<PathBuf, Vec<OsString>> {
    let mut map: BTreeMap<PathBuf, Vec<OsString>> = BTreeMap::new();
    for p in paths {
        let p = p.as_ref();
        let parent = p
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        let name = p
            .file_name()
            .map(|s| s.to_os_string())
            // No `file_name` (e.g., path ends in `..`): fall back to the full
            // path so the entry isn't lost.
            .unwrap_or_else(|| OsString::from(p.as_os_str()));
        map.entry(parent).or_default().push(name);
    }
    map
}

#[cfg(test)]
mod tests {
    use super::*;

    fn os(s: &str) -> OsString {
        OsString::from(s)
    }

    #[test]
    fn empty_input_returns_empty_map() {
        let v: Vec<&str> = vec![];
        let g = group_by_directory(&v);
        assert!(g.is_empty());
    }

    #[test]
    fn single_path_with_parent() {
        let g = group_by_directory(&["src/main.rs"]);
        assert_eq!(g.len(), 1);
        assert_eq!(g.get(&PathBuf::from("src")), Some(&vec![os("main.rs")]));
    }

    #[test]
    fn multiple_paths_same_directory() {
        let g = group_by_directory(&["src/a.rs", "src/b.rs", "src/c.rs"]);
        assert_eq!(g.len(), 1);
        assert_eq!(
            g.get(&PathBuf::from("src")),
            Some(&vec![os("a.rs"), os("b.rs"), os("c.rs")])
        );
    }

    #[test]
    fn paths_across_directories_split() {
        let g = group_by_directory(&["src/a.rs", "docs/x.md", "src/b.rs"]);
        assert_eq!(g.len(), 2);
        assert_eq!(
            g.get(&PathBuf::from("src")),
            Some(&vec![os("a.rs"), os("b.rs")])
        );
        assert_eq!(g.get(&PathBuf::from("docs")), Some(&vec![os("x.md")]));
    }

    #[test]
    fn root_level_files_bucket_under_empty_path() {
        let g = group_by_directory(&["README.md", "LICENSE"]);
        assert_eq!(
            g.get(&PathBuf::new()),
            Some(&vec![os("README.md"), os("LICENSE")])
        );
    }

    #[test]
    fn nested_directories_preserved_as_keys() {
        let g = group_by_directory(&["src/cmd/grep.rs", "src/cmd/hash.rs", "src/main.rs"]);
        assert_eq!(g.len(), 2);
        assert!(g.contains_key(&PathBuf::from("src/cmd")));
        assert!(g.contains_key(&PathBuf::from("src")));
    }

    #[test]
    fn input_order_preserved_within_bucket() {
        let g = group_by_directory(&["src/z.rs", "src/a.rs", "src/m.rs"]);
        assert_eq!(
            g.get(&PathBuf::from("src")),
            Some(&vec![os("z.rs"), os("a.rs"), os("m.rs")]),
            "intra-bucket order must match input order (callers can sort if they want)"
        );
    }

    #[test]
    fn btreemap_key_order_is_sorted() {
        // Demonstrates the doc claim: iteration order is sorted by key.
        let g = group_by_directory(&["src/a", "docs/a", "tests/a"]);
        let keys: Vec<&PathBuf> = g.keys().collect();
        assert_eq!(
            keys,
            vec![
                &PathBuf::from("docs"),
                &PathBuf::from("src"),
                &PathBuf::from("tests"),
            ]
        );
    }
}
