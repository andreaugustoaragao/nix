//! Private, atomic, content-addressed recovery with lossless compression.
//!
//! Identical outputs share a file. Retention bounds the cache; callers must
//! return original output whenever a complete recovery payload cannot be saved.

use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

use flate2::{Compression, read::GzDecoder, write::GzEncoder};
use sha2::{Digest, Sha256};

fn digest(raw: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    Sha256::digest(raw)
        .iter()
        .flat_map(|byte| {
            [
                HEX[(byte >> 4) as usize] as char,
                HEX[(byte & 15) as usize] as char,
            ]
        })
        .collect()
}

#[derive(Clone, Copy)]
pub struct Limits {
    pub files: usize,
    pub bytes: u64,
    pub age: Duration,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            files: 200,
            bytes: 64 * 1024 * 1024,
            age: Duration::from_secs(30 * 86400),
        }
    }
}

impl Limits {
    pub fn from_env() -> Self {
        fn number(name: &str, default: u64) -> u64 {
            std::env::var(name)
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(default)
        }
        let defaults = Self::default();
        Self {
            files: number("PI_RS_RECOVERY_MAX_FILES", defaults.files as u64) as usize,
            bytes: number("PI_RS_RECOVERY_MAX_BYTES", defaults.bytes),
            age: Duration::from_secs(number("PI_RS_RECOVERY_MAX_DAYS", 30).saturating_mul(86400)),
        }
    }
}

fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    options.write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
}

fn regular(path: &Path) -> io::Result<()> {
    if !fs::symlink_metadata(path)?.file_type().is_file() {
        return Err(io::Error::other("recovery path is not a regular file"));
    }
    Ok(())
}

/// Decode a plain or gzip file. Content-addressed names also verify integrity.
pub fn read(path: &Path) -> io::Result<Vec<u8>> {
    let stored = fs::read(path)?;
    let raw = if stored.starts_with(&[0x1f, 0x8b]) {
        let mut raw = Vec::new();
        GzDecoder::new(stored.as_slice()).read_to_end(&mut raw)?;
        raw
    } else {
        stored
    };
    if let Some(name) = path.file_name().and_then(|s| s.to_str()) {
        let prefix = name.split('.').next().unwrap_or("");
        if prefix.len() == 24
            && prefix.bytes().all(|b| b.is_ascii_hexdigit())
            && !digest(&raw).starts_with(prefix)
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "recovery checksum mismatch",
            ));
        }
    }
    Ok(raw)
}

pub fn store(raw: &[u8], directory: &Path, limits: Limits) -> io::Result<PathBuf> {
    if limits.files == 0 || limits.bytes == 0 || limits.age.is_zero() {
        return Err(io::Error::other("recovery storage is disabled"));
    }
    let mut builder = DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(directory)?;
    if !fs::symlink_metadata(directory)?.file_type().is_dir() {
        return Err(io::Error::other("recovery directory must not be a symlink"));
    }
    let lock_path = directory.join(".lock");
    if lock_path.exists() {
        regular(&lock_path)?;
    }
    let lock = private_options()
        .create(true)
        .truncate(false)
        .open(lock_path)?;
    lock.lock()?;

    let digest = digest(raw);
    let stem = &digest[..24];
    for suffix in ["log", "log.gz"] {
        let path = directory.join(format!("{stem}.{suffix}"));
        if path.exists() {
            regular(&path)?;
            if read(&path)? != raw {
                return Err(io::Error::other("recovery hash collision"));
            }
            File::open(&path)?.set_modified(SystemTime::now())?;
            prune(directory, &path, limits)?;
            return Ok(path);
        }
    }

    let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(raw)?;
    let compressed = encoder.finish()?;
    let (payload, suffix) = if compressed.len() < raw.len() {
        (compressed.as_slice(), "log.gz")
    } else {
        (raw, "log")
    };
    if payload.len() as u64 > limits.bytes {
        return Err(io::Error::other(
            "complete recovery exceeds the storage budget",
        ));
    }
    let path = directory.join(format!("{stem}.{suffix}"));
    static SERIAL: AtomicU64 = AtomicU64::new(0);
    let temp = directory.join(format!(
        ".{}_{}.tmp",
        std::process::id(),
        SERIAL.fetch_add(1, Ordering::Relaxed)
    ));
    let save = || -> io::Result<()> {
        let mut file = private_options().create_new(true).open(&temp)?;
        file.write_all(payload)?;
        file.sync_all()?;
        // The complete file becomes visible atomically without overwriting.
        fs::hard_link(&temp, &path)?;
        Ok(())
    };
    let outcome = save();
    let _ = fs::remove_file(&temp);
    outcome?;
    if let Err(error) = prune(directory, &path, limits) {
        let _ = fs::remove_file(&path);
        return Err(error);
    }
    Ok(path)
}

fn prune(directory: &Path, current: &Path, limits: Limits) -> io::Result<()> {
    let now = SystemTime::now();
    let mut entries = Vec::new();
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        if !entry.file_type()?.is_file() {
            continue;
        }
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.ends_with(".log") && !name.ends_with(".log.gz") && !name.ends_with(".tmp") {
            continue;
        }
        let metadata = entry.metadata()?;
        let modified = metadata.modified()?;
        let age = now.duration_since(modified).unwrap_or_default();
        if path != current
            && (age > limits.age || (name.ends_with(".tmp") && age > Duration::from_secs(86400)))
        {
            fs::remove_file(path)?;
        } else if !name.ends_with(".tmp") {
            entries.push((modified, path, metadata.len()));
        }
    }
    entries.sort_by_key(|e| e.0);
    let mut count = entries.len();
    let mut bytes: u64 = entries.iter().map(|e| e.2).sum();
    for (_, path, size) in entries {
        if count <= limits.files && bytes <= limits.bytes {
            break;
        }
        if path == current {
            continue;
        }
        fs::remove_file(path)?;
        count -= 1;
        bytes -= size;
    }
    if count > limits.files || bytes > limits.bytes {
        return Err(io::Error::other("recovery retention budget exceeded"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repeated_and_concurrent_outputs_share_one_complete_private_file() {
        let directory = tempfile::tempdir().unwrap();
        let raw = "a diagnostic containing unicode: λ\n"
            .repeat(4000)
            .into_bytes();
        let paths = std::thread::scope(|scope| {
            (0..8)
                .map(|_| scope.spawn(|| store(&raw, directory.path(), Limits::default()).unwrap()))
                .collect::<Vec<_>>()
                .into_iter()
                .map(|h| h.join().unwrap())
                .collect::<Vec<_>>()
        });
        assert!(paths.iter().all(|p| p == &paths[0]));
        assert_eq!(read(&paths[0]).unwrap(), raw);
        assert!(fs::metadata(&paths[0]).unwrap().len() < raw.len() as u64 / 10);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&paths[0]).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 2); // payload and lock
    }

    #[test]
    fn retention_keeps_current_and_evicts_oldest_without_partial_files() {
        let directory = tempfile::tempdir().unwrap();
        let limits = Limits {
            files: 2,
            ..Limits::default()
        };
        let oldest = store(b"first payload", directory.path(), limits).unwrap();
        File::open(&oldest)
            .unwrap()
            .set_modified(SystemTime::UNIX_EPOCH)
            .unwrap();
        let second = store(b"second payload", directory.path(), limits).unwrap();
        let latest = store(b"third payload", directory.path(), limits).unwrap();
        assert!(!oldest.exists());
        assert_eq!(read(&second).unwrap(), b"second payload");
        assert_eq!(read(&latest).unwrap(), b"third payload");
        assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 3);
    }

    #[test]
    fn corrupt_content_is_neither_returned_nor_overwritten() {
        let directory = tempfile::tempdir().unwrap();
        let path = store(b"a small payload", directory.path(), Limits::default()).unwrap();
        fs::write(&path, b"corrupted").unwrap();
        assert!(read(&path).is_err());
        assert!(store(b"a small payload", directory.path(), Limits::default()).is_err());
        assert_eq!(fs::read(path).unwrap(), b"corrupted");
    }
}
