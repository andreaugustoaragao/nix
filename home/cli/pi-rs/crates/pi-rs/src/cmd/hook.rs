//! `pi-rs hook <agent>` subcommand.
//!
//! Protocol adapter for per-agent bash hooks. Each agent uses a slightly
//! different JSON envelope; this subcommand reads stdin, dispatches to the
//! right adapter, and writes the agent-expected response to stdout.
//!
//! Per-agent protocols:
//!
//! - **cursor** (preToolUse): stdin JSON has `tool_input.command`.
//!   Passthrough → exit 0, stdout `{}`. Rewrite → exit 0, stdout JSON:
//!   `{"permission": "allow", "updated_input": {"command": "<new>"}}`.
//! Tokenization failures, missing keys, and parse errors all map to
//! passthrough so a malformed hook input never breaks the agent.

use std::io::Read;

use clap::{Args, ValueEnum};
use serde_json::{Value, json};

use crate::rewrite::{Decision, config::Config, rewrite};

#[derive(ValueEnum, Clone, Copy, Debug)]
pub enum Agent {
    /// Cursor / cursor-agent preToolUse hook protocol.
    Cursor,
}

#[derive(Args, Debug)]
pub struct HookArgs {
    /// Which agent's protocol to speak.
    #[arg(value_enum)]
    pub agent: Agent,
}

pub fn run(args: HookArgs) -> anyhow::Result<()> {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input)?;

    let out = decide(&input, args.agent)?;
    if !out.is_empty() {
        println!("{out}");
    }
    Ok(())
}

/// Pure-function core of `run`: resolve the input string + agent to the
/// stdout payload. Extracted from `run` so it can be unit-tested directly
/// without spawning a subprocess.
///
/// Any input shape that the hook can't parse — empty stdin, malformed
/// JSON, missing `tool_input.command`, etc. — resolves to the agent's
/// passthrough form. Hooks must never break the agent.
fn decide(input: &str, agent: Agent) -> serde_json::Result<String> {
    if input.trim().is_empty() {
        return Ok(render_passthrough(agent));
    }
    let payload: Value = match serde_json::from_str(input) {
        Ok(v) => v,
        Err(_) => return Ok(render_passthrough(agent)),
    };
    let command = payload
        .get("tool_input")
        .and_then(|v| v.get("command"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if command.is_empty() {
        return Ok(render_passthrough(agent));
    }
    let config = Config::load();
    match rewrite(command, &config) {
        Decision::Passthrough => Ok(render_passthrough(agent)),
        Decision::Rewrite(new_cmd) => render_rewrite(agent, &payload, &new_cmd),
    }
}

/// Per-agent passthrough output.
///
/// Cursor expects `{}` so the hook response is always a valid JSON document.
fn render_passthrough(agent: Agent) -> String {
    match agent {
        Agent::Cursor => "{}".into(),
    }
}

/// Per-agent rewrite envelope.
fn render_rewrite(agent: Agent, _payload: &Value, new_cmd: &str) -> serde_json::Result<String> {
    match agent {
        Agent::Cursor => render_cursor_rewrite(new_cmd),
    }
}

fn render_cursor_rewrite(new_cmd: &str) -> serde_json::Result<String> {
    let response = json!({
        "permission": "allow",
        "updated_input": { "command": new_cmd },
    });
    serde_json::to_string(&response)
}

#[cfg(test)]
mod tests {
    use super::*;


    #[test]
    fn decide_empty_input_is_passthrough() {
        assert_eq!(decide("", Agent::Cursor).unwrap(), "{}");
    }

    #[test]
    fn decide_malformed_json_is_passthrough() {
        assert_eq!(decide("{ malformed", Agent::Cursor).unwrap(), "{}");
    }

    #[test]
    fn decide_missing_command_is_passthrough() {
        let input = r#"{"tool_input":{"description":"no cmd"}}"#;
        assert_eq!(decide(input, Agent::Cursor).unwrap(), "{}");
    }
    #[test]
    fn decide_unknown_command_is_passthrough() {
        // No rule for `foozle` — the rewrite oracle resolves to passthrough,
        // and decide() then emits the agent's passthrough form.
        let input = r#"{"tool_name":"Bash","tool_input":{"command":"foozle"}}"#;
        assert_eq!(decide(input, Agent::Cursor).unwrap(), "{}");
    }

    #[test]
    fn cursor_passthrough_is_empty_object() {
        assert_eq!(render_passthrough(Agent::Cursor), "{}");
    }

    #[test]
    fn cursor_rewrite_envelope_shape() {
        let out = render_cursor_rewrite("pi-rs git status").unwrap();
        let parsed: Value = serde_json::from_str(&out).unwrap();

        assert_eq!(parsed.get("permission"), Some(&json!("allow")));
        let updated = parsed.get("updated_input").expect("updated_input");
        assert_eq!(updated.get("command"), Some(&json!("pi-rs git status")));
    }
}
