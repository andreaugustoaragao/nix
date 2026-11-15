---
name: shell
description: Execute the literal command in an explicit shell request through the available terminal tool, subject to current sandbox and project policy.
---

# Literal shell command

Use only when the user explicitly invokes this skill in the current client and supplies a literal command: for example Codex `$shell` or structured skill input, `/shell`, or PI `/skill:shell`. Pass the supplied command unchanged to the terminal tool; use the requested working directory when supplied. If no command was provided, report that the invocation needs a literal command.

Execution still follows the terminal tool's sandbox, approvals, and higher-priority/project instructions. Do not interpret skill invocation as authorization to change credentials or bypass restrictions. If the command is prohibited or needs approval, state the concrete constraint. Avoid unrelated repository inspection.

Report exit status and relevant output accurately. A running process is not completion; retain its real handle and observe it using the tool's supported interface.
