//! Rewrite config loader: `~/.config/pi-rs/rewrite.toml`.
//!
//! Schema:
//!
//! ```toml
//! [rewrite]
//! # argv[0] basenames to never rewrite, even if a rule matches.
//! exclude = ["curl", "playwright"]
//! ```
//!
//! Missing file → empty exclude list. Malformed file → empty exclude list,
//! no error surfaced. The oracle must never fail a rewrite because of
//! config IO; hooks are on a hot path.

use serde::Deserialize;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Config {
    /// argv[0] basenames that should never be rewritten.
    pub exclude: Vec<String>,
}

#[derive(Debug, Default, Deserialize)]
struct ConfigFile {
    #[serde(default)]
    rewrite: RewriteSection,
}

#[derive(Debug, Default, Deserialize)]
struct RewriteSection {
    #[serde(default)]
    exclude: Vec<String>,
}

impl Config {
    /// Load from the default path (`~/.config/pi-rs/rewrite.toml`). Errors
    /// are swallowed and a default [`Config`] is returned — hooks must
    /// never fail because of config IO.
    pub fn load() -> Self {
        Self::load_from_path(default_path().as_deref()).unwrap_or_default()
    }

    /// Load from an explicit path. `None` returns the default. IO errors
    /// other than "not found" propagate; parse errors fall back to default.
    pub fn load_from_path(path: Option<&Path>) -> io::Result<Self> {
        let Some(path) = path else {
            return Ok(Self::default());
        };
        let content = match std::fs::read_to_string(path) {
            Ok(s) => s,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(e) => return Err(e),
        };
        // Parse errors → default. Don't surface to the hook layer.
        let parsed: ConfigFile = toml::from_str(&content).unwrap_or_default();
        Ok(Self {
            exclude: parsed.rewrite.exclude,
        })
    }
}

/// `$XDG_CONFIG_HOME/pi-rs/rewrite.toml` (resolves to `~/.config/pi-rs/...`
/// on Linux). `None` only when neither `$HOME` nor `$XDG_CONFIG_HOME` exist.
fn default_path() -> Option<PathBuf> {
    dirs::config_dir().map(|d| d.join("pi-rs").join("rewrite.toml"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn default_config_has_empty_exclude() {
        let c = Config::default();
        assert!(c.exclude.is_empty());
    }

    #[test]
    fn missing_file_returns_default() {
        let tmp = TempDir::new().unwrap();
        let p = tmp.path().join("absent.toml");
        let c = Config::load_from_path(Some(&p)).unwrap();
        assert_eq!(c, Config::default());
    }

    #[test]
    fn empty_file_returns_default() {
        let tmp = TempDir::new().unwrap();
        let p = tmp.path().join("empty.toml");
        std::fs::write(&p, "").unwrap();
        let c = Config::load_from_path(Some(&p)).unwrap();
        assert_eq!(c, Config::default());
    }

    #[test]
    fn parses_exclude_list() {
        let tmp = TempDir::new().unwrap();
        let p = tmp.path().join("rewrite.toml");
        std::fs::write(
            &p,
            "[rewrite]\nexclude = [\"curl\", \"playwright\"]\n",
        )
        .unwrap();
        let c = Config::load_from_path(Some(&p)).unwrap();
        assert_eq!(c.exclude, vec!["curl".to_string(), "playwright".to_string()]);
    }

    #[test]
    fn malformed_toml_falls_back_to_default() {
        // Defensive: corrupt config must not break hooks.
        let tmp = TempDir::new().unwrap();
        let p = tmp.path().join("bad.toml");
        std::fs::write(&p, "this is not valid toml = = =").unwrap();
        let c = Config::load_from_path(Some(&p)).unwrap();
        assert_eq!(c, Config::default());
    }

    #[test]
    fn missing_rewrite_section_returns_default() {
        let tmp = TempDir::new().unwrap();
        let p = tmp.path().join("other.toml");
        std::fs::write(&p, "[other]\nfoo = 1\n").unwrap();
        let c = Config::load_from_path(Some(&p)).unwrap();
        assert!(c.exclude.is_empty());
    }

    #[test]
    fn empty_exclude_in_section_returns_default() {
        let tmp = TempDir::new().unwrap();
        let p = tmp.path().join("rewrite.toml");
        std::fs::write(&p, "[rewrite]\nexclude = []\n").unwrap();
        let c = Config::load_from_path(Some(&p)).unwrap();
        assert!(c.exclude.is_empty());
    }

    #[test]
    fn none_path_returns_default() {
        let c = Config::load_from_path(None).unwrap();
        assert_eq!(c, Config::default());
    }
}
