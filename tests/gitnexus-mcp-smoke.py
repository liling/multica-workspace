import asyncio
import json
import os
from pathlib import Path
import subprocess
import tempfile

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


def result_json(result, operation: str) -> dict:
    assert not result.is_error, f"GitNexus {operation} returned an MCP error"
    text_items = [item.text for item in result.content if getattr(item, "type", None) == "text"]
    assert text_items, f"GitNexus {operation} returned no text content"
    try:
        payload = json.loads(text_items[0].split("\n\n---", 1)[0])
    except json.JSONDecodeError as error:
        raise AssertionError(f"GitNexus {operation} returned non-JSON content: {text_items[0]!r}") from error
    assert isinstance(payload, dict), f"GitNexus {operation} returned a non-object payload"
    return payload


async def main() -> None:
    with tempfile.TemporaryDirectory(prefix="gitnexus-mcp-smoke-") as directory:
        repo = Path(directory)
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        (repo / "app.js").write_text(
            "export function greet(name) { return `hello ${name}`; }\n"
            "export function caller() { return greet('GitNexus smoke'); }\n",
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
                query_payload = result_json(query, "query")
                definitions = query_payload.get("definitions")
                assert isinstance(definitions, list) and any(
                    item.get("name") == "greet" and item.get("filePath") == "app.js"
                    for item in definitions if isinstance(item, dict)
                ), f"GitNexus query did not return the greet definition: {query_payload!r}"

                context = await session.call_tool("context", {"name": "greet"})
                context_payload = result_json(context, "context")
                assert context_payload.get("status") == "found" and context_payload.get("symbol", {}).get("name") == "greet", \
                    f"GitNexus context did not resolve greet: {context_payload!r}"

                impact = await session.call_tool("impact", {"direction": "upstream", "target": "greet"})
                impact_payload = result_json(impact, "impact")
                assert impact_payload.get("impactedCount", 0) >= 1, \
                    f"GitNexus impact did not include a caller: {impact_payload!r}"
                assert "caller" in json.dumps(impact_payload.get("byDepth", {})), \
                    f"GitNexus impact did not identify the expected caller: {impact_payload!r}"
                print("PASS GitNexus MCP query=definition:greet context=found:greet impact=caller->greet")


asyncio.run(main())
