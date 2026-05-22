//! `pi-rs hook <agent>` subcommand.
//!
//! Protocol adapter for per-agent bash hooks. Each agent uses a slightly
//! different JSON envelope; this subcommand reads stdin, dispatches to the
//! right adapter, and writes the agent-expected response to stdout.
//!
//! Per-agent protocols:
//!
//! - **claude** (PreToolUse): stdin JSON has `tool_name`, `tool_input.command`.
//!   Passthrough → exit 0, empty stdout. Rewrite → exit 0, stdout JSON:
//!   `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow", "permissionDecisionReason": "...", "updatedInput": {<original tool_input with command replaced>}}}`.
//!
//! - **cursor** (preToolUse): stdin JSON has `tool_input.command`.
//!   Passthrough → exit 0, stdout `{}`. Rewrite → exit 0, stdout JSON:
//!   `{"permission": "allow", "updated_input": {"command": "<new>"}}`.
//!
//! Tokenization failures, missing keys, and parse errors all map to
//! passthrough so a malformed hook input never breaks the agent.

use std::io::Read;

use clap::{Args, ValueEnum};
use serde_json::{Value, json};

use crate::rewrite::{Decision, config::Config, rewrite};

#[derive(ValueEnum, Clone, Copy, Debug)]
pub enum Agent {
    /// Claude Code PreToolUse hook protocol.
    Claude,
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
/// Claude is happy with empty stdout. Cursor expects `{}` so the hook
/// response is always a valid JSON document.
fn render_passthrough(agent: Agent) -> String {
    match agent {
        Agent::Claude => String::new(),
        Agent::Cursor => "{}".into(),
    }
}

/// Per-agent rewrite envelope.
fn render_rewrite(agent: Agent, payload: &Value, new_cmd: &str) -> serde_json::Result<String> {
    match agent {
        Agent::Claude => render_claude_rewrite(payload, new_cmd),
        Agent::Cursor => render_cursor_rewrite(new_cmd),
    }
}

fn render_claude_rewrite(payload: &Value, new_cmd: &str) -> serde_json::Result<String> {
    // Preserve all original tool_input fields (description, timeout, etc.)
    // and only override `command`.
    let mut tool_input = payload
        .get("tool_input")
        .cloned()
        .unwrap_or_else(|| json!({}));
    if let Some(map) = tool_input.as_object_mut() {
        map.insert("command".into(), Value::String(new_cmd.to_string()));
    } else {
        // tool_input wasn't an object — shouldn't happen, but synthesize.
        tool_input = json!({ "command": new_cmd });
    }

    let response = json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": "pi-rs auto-rewrite",
            "updatedInput": tool_input,
        }
    });
    serde_json::to_string(&response)
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
    fn claude_passthrough_is_empty() {
        assert_eq!(render_passthrough(Agent::Claude), "");
    }

    #[test]
    fn decide_empty_input_is_passthrough() {
        assert_eq!(decide("", Agent::Claude).unwrap(), "");
        assert_eq!(decide("", Agent::Cursor).unwrap(), "{}");
    }

    #[test]
    fn decide_malformed_json_is_passthrough() {
        assert_eq!(decide("not json", Agent::Claude).unwrap(), "");
        assert_eq!(decide("{ malformed", Agent::Cursor).unwrap(), "{}");
    }

    #[test]
    fn decide_missing_command_is_passthrough() {
        let input = r#"{"tool_name":"Bash","tool_input":{"description":"no cmd"}}"#;
        assert_eq!(decide(input, Agent::Claude).unwrap(), "");
    }

    #[test]
    fn decide_unknown_command_is_passthrough() {
        // No rule for `foozle` — the rewrite oracle resolves to passthrough,
        // and decide() then emits the agent's passthrough form.
        let input = r#"{"tool_name":"Bash","tool_input":{"command":"foozle"}}"#;
        assert_eq!(decide(input, Agent::Claude).unwrap(), "");
        assert_eq!(decide(input, Agent::Cursor).unwrap(), "{}");
    }

    #[test]
    fn cursor_passthrough_is_empty_object() {
        assert_eq!(render_passthrough(Agent::Cursor), "{}");
    }

    #[test]
    fn claude_rewrite_envelope_shape() {
        let payload = json!({
            "tool_name": "Bash",
            "tool_input": { "command": "git status", "description": "check repo" }
        });
        let out = render_claude_rewrite(&payload, "pi-rs git status").unwrap();
        let parsed: Value = serde_json::from_str(&out).unwrap();

        // Top-level shape: must have hookSpecificOutput.
        let hso = parsed.get("hookSpecificOutput").expect("hookSpecificOutput");
        assert_eq!(hso.get("hookEventName"), Some(&json!("PreToolUse")));
        assert_eq!(hso.get("permissionDecision"), Some(&json!("allow")));
        assert!(
            hso.get("permissionDecisionReason")
                .and_then(|v| v.as_str())
                .is_some(),
            "permissionDecisionReason must be present"
        );

        // updatedInput: command replaced, OTHER fields preserved.
        let updated = hso.get("updatedInput").expect("updatedInput");
        assert_eq!(updated.get("command"), Some(&json!("pi-rs git status")));
        assert_eq!(
            updated.get("description"),
            Some(&json!("check repo")),
            "original tool_input fields (description) must be preserved"
        );
    }

    #[test]
    fn claude_rewrite_synthesizes_tool_input_when_missing() {
        // Defensive: stdin without a tool_input field shouldn't crash;
        // we synthesize a fresh one with just the rewritten command.
        let payload = json!({ "tool_name": "Bash" });
        let out = render_claude_rewrite(&payload, "pi-rs git status").unwrap();
        let parsed: Value = serde_json::from_str(&out).unwrap();
        let updated = parsed
            .get("hookSpecificOutput")
            .and_then(|v| v.get("updatedInput"))
            .expect("updatedInput");
        assert_eq!(updated.get("command"), Some(&json!("pi-rs git status")));
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
