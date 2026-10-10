"""Expose the pinned dev-browser CLI over MCP without launching a browser at startup."""

import argparse
import asyncio
from typing import Annotated
from urllib.parse import urlsplit

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from mcp.types import ToolAnnotations
from pydantic import Field


OUTPUT_LIMIT = 100_000
mcp = FastMCP("dev-browser", log_level="WARNING")
command = "dev-browser"


async def read_output(stream: asyncio.StreamReader) -> str:
    """Keep draining the pipe after the limit so verbose scripts cannot block."""
    output = bytearray()
    truncated = False
    while chunk := await stream.read(65536):
        remaining = OUTPUT_LIMIT - len(output)
        output.extend(chunk[:remaining])
        truncated |= len(chunk) > remaining
    text = output.decode("utf-8", errors="replace")
    return text + ("\n[output truncated]" if truncated else "")


@mcp.tool(
    annotations=ToolAnnotations(
        readOnlyHint=False, destructiveHint=True, openWorldHint=True
    )
)
async def dev_browser(
    script: Annotated[str, Field(min_length=1)],
    connect: bool | str = True,
    browser: Annotated[str, Field(min_length=1)] = "pi",
    headless: bool = False,
    timeout: Annotated[int, Field(ge=1, le=300)] = 30,
) -> dict[str, str | int]:
    """Control a browser with a JavaScript script through dev-browser.

    By default attach to an existing Chrome/Brave with remote debugging enabled
    (Brave uses port 9222 in this configuration). connect can be a CDP HTTP or
    WebSocket URL; connect=false launches managed Chromium, which requires a
    separately installed Playwright browser. headless only affects managed mode.
    The browser name defaults to the shared Pi profile; keep it unless isolation
    is needed. Discover existing tabs with await browser.listPages(), then use
    await browser.getPage(id). Do not navigate an unrelated existing tab.

    Scripts run in QuickJS, NOT Node.js: no import, require, process, fs, or fetch.
    Top-level await, console, timers and Playwright page methods are available.
    Use await browser.getPage(name) for persistent named pages or browser.newPage()
    for temporary pages cleaned up after the script. Inspect unknown pages with
    await page.snapshotForAI(); interact with page.getByRole(...).click(), fill(),
    and other Playwright methods. Prefer goto(url, {waitUntil: 'domcontentloaded'}).
    Log results with console.log(JSON.stringify(...)). Save screenshots with
    await saveScreenshot(await page.screenshot(), 'name.png'); log the returned
    path to view the image. File helpers are restricted to ~/.dev-browser/tmp/.
    timeout is the script limit in seconds (1–300). Browser state may persist
    after errors; inspect it before retrying an action.
    """
    args = [command, "--browser", browser, "--timeout", str(timeout)]
    if isinstance(connect, str):
        endpoint = urlsplit(connect)
        if endpoint.scheme not in {"http", "https", "ws", "wss"} or not endpoint.netloc:
            raise ToolError("connect must be true, false, or an HTTP/WebSocket CDP URL")
        args.extend(["--connect", connect])
    elif connect:
        args.append("--connect")
    if headless:
        args.append("--headless")

    try:
        process = await asyncio.create_subprocess_exec(
            *args,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except OSError as exc:
        raise ToolError(f"Cannot start dev-browser: {exc}") from exc

    async def exchange():
        async def send_script():
            try:
                process.stdin.write(script.encode("utf-8"))
                await process.stdin.drain()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                process.stdin.close()

        stdout, stderr, _, _ = await asyncio.gather(
            read_output(process.stdout),
            read_output(process.stderr),
            send_script(),
            process.wait(),
        )
        return stdout, stderr

    try:
        stdout, stderr = await asyncio.wait_for(exchange(), timeout + 10)
    except TimeoutError as exc:
        raise ToolError(
            f"dev-browser did not finish within {timeout + 10}s. "
            "Check the browser's CDP connection and inspect page state before retrying."
        ) from exc
    finally:
        # Reap this CLI on cancellation/timeout without stopping the shared daemon.
        if process.returncode is None:
            process.kill()
            await process.wait()

    if process.returncode != 0:
        raise ToolError(f"dev-browser exited {process.returncode}\n{stderr}\n{stdout}")
    return {"stdout": stdout, "stderr": stderr, "exit_code": process.returncode}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", default=command, help="dev-browser executable")
    command = parser.parse_args().command
    mcp.run(transport="stdio")
