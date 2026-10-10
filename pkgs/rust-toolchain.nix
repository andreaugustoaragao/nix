{ rust-bin, ... }:

# One pinned upstream toolchain for development and pi-rs builds on every host.
rust-bin.fromRustupToolchainFile ../rust-toolchain.toml
