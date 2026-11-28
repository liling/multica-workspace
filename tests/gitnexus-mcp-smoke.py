import asyncio
import os
from pathlib import Path
import subprocess
import tempfile

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main() -> None:
    with tempfile.TemporaryDirectory(prefix="gitnexus-mcp-smoke-") as directory:
        repo = Path(directory)
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        (repo / "app.js").write_text(
            "export function greet(name) { return `hello ${name}`; }\n",
            encoding="utf-8",
        )
        subprocess.run(
            ["gitnexus", "analyze", "--index-only", str(repo)],
            check=True,
            env={**os.environ, "GITNEXUS_LBUG_EXTENSION_INSTALL": "load-only"},
        )

        server = StdioServerParameters(command="gitnexus", args=["mcp"], cwd=str(repo))
        async with stdio_client(server) as (read_stream, write_stream):
            async with ClientSession(read_stream, write_stream) as session:
                await session.initialize()
                tools = await session.list_tools()
                expected = {"query", "context", "impact"}
                found = {tool.name for tool in tools.tools}
                assert expected <= found, f"missing MCP tools: {expected - found}"

                query = await session.call_tool(
                    "query",
                    {"search_query": "greet", "repo": str(repo), "response_sections": ["definitions"]},
                )
                assert not query.is_error and query.content, "GitNexus query returned no result"
                context = await session.call_tool("context", {"name": "greet"})
                assert not context.is_error and context.content, "GitNexus context returned no result"
                impact = await session.call_tool("impact", {"direction": "upstream", "target": "greet"})
                assert not impact.is_error and impact.content, "GitNexus impact returned no result"
                print("GitNexus MCP discovered and called query, context, impact")


asyncio.run(main())
