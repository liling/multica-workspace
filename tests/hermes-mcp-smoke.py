import asyncio
from importlib.metadata import version
import sys

from tools import mcp_tool as hermes_mcp_tool


server_code = '''
from mcp.server.mcpserver import MCPServer

server = MCPServer(name="workspace-smoke")

@server.tool()
def add(left: int, right: int) -> int:
    return left + right

server.run()
'''

async def main() -> None:
    assert version("mcp") == "2.3.0"
    assert hermes_mcp_tool._ensure_mcp_sdk()
    params = hermes_mcp_tool.StdioServerParameters(command=sys.executable, args=["-c", server_code])
    async with hermes_mcp_tool.stdio_client(params) as (read_stream, write_stream):
        async with hermes_mcp_tool.ClientSession(read_stream, write_stream) as session:
            await session.initialize()
            tools = await session.list_tools()
            assert any(tool.name == "add" for tool in tools.tools)
            result = await session.call_tool("add", {"left": 19, "right": 23})
            assert not result.is_error
            assert result.content[0].text == "42"


asyncio.run(main())
