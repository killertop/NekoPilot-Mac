//! Tauri command handlers — the UI-facing surface.
//!
//! Each submodule groups commands by domain. Anything the frontend
//! `invoke()`s is either here, or in `crate::core`/`crate::engine` where
//! the command is tightly coupled to lifecycle/platform state.

pub mod config_build;
pub mod config_fetch;
pub mod config_write;
pub mod dns;
pub mod network;
pub mod node_delay;
pub mod prestart;
pub mod rule_sets;
pub mod settings;
pub mod shell;
pub mod subscription;
pub mod theme;
pub mod whitelist;
