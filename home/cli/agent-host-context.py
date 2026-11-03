"""Report current terminal evidence without contacting a host or reading secrets."""

import json
import os
import shutil


VARIABLES = (
    "HERDR_ENV",
    "HERDR_PANE_ID",
    "HERDR_SOCKET_PATH",
    "HC_TERMINAL_ID",
    "HC_TERMINAL_SOCKET",
    "ORCA_PANE_KEY",
    "ORCA_TAB_ID",
    "ORCA_WORKTREE_ID",
    "ORCA_STRUCTURED_SESSION",
    "ORCA_AGENT_SESSION_ID",
    "ORCA_CLI_COMMAND",
    "ORCA_DEV_REPO_ROOT",
)
COMMANDS = ("herdr", "hc", "herdr-app", "orca", "orca-ide", "orca-desktop", "orca-dev")


if __name__ == "__main__":
    print(json.dumps({
        "environment": {key: os.environ[key] for key in VARIABLES if key in os.environ},
        "commands": {command: shutil.which(command) for command in COMMANDS},
    }, indent=2))
