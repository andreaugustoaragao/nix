//! Layer 1 compression primitives.
//!
//! Pure functions that take raw tool output and return a compressed form.
//! Used by both the per-tool wrappers in [`crate::cmd::filters`] and (where
//! appropriate) the existing pi-rs commands. Each submodule implements one
//! cross-cutting strategy.
//!
//! Strategies (one per submodule):
//!
//! - [`tee`]: truncate to head+tail, save the full raw payload to
//!   `~/.local/share/pi-rs/tee/{ts}_{cmd}.log`, return a pointer the LLM
//!   can read on demand.
//! - [`dedupe`]: collapse N identical adjacent lines into a single line
//!   tagged with a count.
//! - [`progress`]: drop progress-bar lines, percent counters, and other
//!   transient terminal noise.
//! - [`group`]: aggregate paths or items by directory / category, emitting
//!   a compact summary instead of a flat list.
//! - [`failures`]: from a stream of test-runner output, keep only the
//!   failing test lines and their file:line references.
//!
//! Derived from `rtk-ai/rtk@v0.40.0` (Apache-2.0). See workspace `NOTICE`.

pub mod dedupe;
pub mod failures;
pub mod group;
pub mod progress;
pub mod tee;
