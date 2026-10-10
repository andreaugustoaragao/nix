"""Exercise the installed MCP launcher with a deterministic browser CLI fixture."""

import asyncio
from datetime import timedelta
import json
import os
from pathlib import Path
import sys
import tempfile

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def check(launcher: str):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        marker = root / "shell-was-run"
        pid_file = root / "slow.pid"
        fixture = root / "browser"
        fixture.write_text(
            f"#!{sys.executable}\n"
            "import json, os, pathlib, sys, time\n"
            "script = sys.stdin.read()\n"
            "if script == 'fail':\n"
            "    print('CDP unavailable', file=sys.stderr)\n"
            "    sys.exit(7)\n"
            "if script == 'verbose':\n"
            "    print('x' * 200000)\n"
            "    print('y' * 200000, file=sys.stderr)\n"
            "    sys.exit(0)\n"
            "if script == 'slow':\n"
            f"    pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid()))\n"
            "    time.sleep(60)\n"
            "print(json.dumps({'args': sys.argv[1:], 'script': script}))\n"
        )
        fixture.chmod(0o755)
        server = StdioServerParameters(
            command=launcher, args=["--command", str(fixture)]
        )
        async with stdio_client(server) as (read, write):
            async with ClientSession(
                read, write, read_timeout_seconds=timedelta(seconds=30)
            ) as session:
                await session.initialize()
                tools = (await session.list_tools()).tools
                assert [tool.name for tool in tools] == ["dev_browser"]
                assert tools[0].annotations.readOnlyHint is False
                assert tools[0].inputSchema["required"] == ["script"]

                script = f"console.log('literal');\n$(touch {marker})"
                result = await session.call_tool("dev_browser", {"script": script})
                assert not result.isError, result
                output = json.loads(result.structuredContent["stdout"])
                assert output == {
                    "args": ["--browser", "pi", "--timeout", "30", "--connect"],
                    "script": script,
                }
                assert not marker.exists(), "Script must travel through stdin, not a shell"

                result = await session.call_tool(
                    "dev_browser",
                    {"script": "url", "connect": "http://127.0.0.1:9223", "timeout": 5},
                )
                output = json.loads(result.structuredContent["stdout"])
                assert output["args"][-2:] == ["--connect", "http://127.0.0.1:9223"]
                result = await session.call_tool(
                    "dev_browser", {"script": "managed", "connect": False, "headless": True}
                )
                output = json.loads(result.structuredContent["stdout"])
                assert "--connect" not in output["args"] and "--headless" in output["args"]

                for args in (
                    {"script": "", "timeout": 1},
                    {"script": "invalid", "timeout": 0},
                    {"script": "invalid", "timeout": 301},
                    {"script": "invalid", "connect": "--headless"},
                ):
                    assert (await session.call_tool("dev_browser", args)).isError

                result = await session.call_tool("dev_browser", {"script": "fail"})
                assert result.isError
                assert "exited 7" in result.content[0].text
                assert "CDP unavailable" in result.content[0].text
                result = await session.call_tool("dev_browser", {"script": "verbose"})
                assert not result.isError
                for stream in ("stdout", "stderr"):
                    output = result.structuredContent[stream]
                    assert len(output) < 101000 and output.endswith("[output truncated]")

                result = await session.call_tool(
                    "dev_browser", {"script": "slow", "timeout": 1}
                )
                assert result.isError and "did not finish within 11s" in result.content[0].text
                pid = int(pid_file.read_text())
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError("Timed-out browser CLI was not reaped")

        # Discovery must work even when no browser/runtime is available yet.
        server.args = ["--command", str(root / "missing-browser")]
        async with stdio_client(server) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                assert (await session.list_tools()).tools[0].name == "dev_browser"
                result = await session.call_tool("dev_browser", {"script": "missing"})
                assert result.isError and "Cannot start dev-browser" in result.content[0].text
    print("Browser MCP protocol, arguments, errors, output limits, and timeout cleanup passed")


if __name__ == "__main__":
    asyncio.run(check(sys.argv[1]))
