import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile


class AppServer:
    def __init__(self, home: Path, cwd: Path) -> None:
        environment = {**os.environ, "CODEX_HOME": str(home)}
        self.process = subprocess.Popen(
            ["codex", "app-server", "--stdio"],
            cwd=cwd,
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.next_id = 1

    def request(self, method: str, params: dict) -> dict:
        request_id = self.next_id
        self.next_id += 1
        self.process.stdin.write(json.dumps({"id": request_id, "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        while True:
            if not self.selector.select(timeout=45):
                self.process.terminate()
                self.process.wait(timeout=10)
                stderr = self.process.stderr.read(4000)
                raise AssertionError(f"Codex app-server timed out on {method}; stderr={stderr}")
            line = self.process.stdout.readline()
            if not line:
                raise AssertionError(f"Codex app-server exited on {method}: {self.process.stderr.read(4000)}")
            message = json.loads(line)
            if message.get("id") == request_id:
                assert "error" not in message, f"Codex {method} failed: {message['error']}"
                return message.get("result", {})

    def close(self) -> None:
        self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.selector.close()


def main() -> None:
    home = Path(tempfile.mkdtemp(prefix=".codex-appserver-smoke-", dir=Path.home()))
    (home / "skills/gitnexus-cli").mkdir(parents=True)
    (home / "skills/gitnexus-cli/SKILL.md").write_text(
        "---\nname: gitnexus-cli\ndescription: User override smoke fixture.\n---\n\nUser skill stays.\n",
        encoding="utf-8",
    )
    try:
      with tempfile.TemporaryDirectory(prefix="codex-gitnexus-smoke-") as directory:
        repo = Path(directory)
        (repo / "app.js").write_text(
            "export function target() { return 'ok'; }\n"
            "export function caller() { return target(); }\n",
            encoding="utf-8",
        )
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(["gitnexus", "analyze", "--index-only", str(repo)], check=True)

        app = AppServer(home, repo)
        try:
            app.request("initialize", {"clientInfo": {"name": "mem0-workspace-smoke", "version": "1"}})
            skills = app.request("skills/list", {"cwds": [str(repo)], "forceReload": True})
            skill_rows = [skill for group in skills.get("data", []) for skill in group.get("skills", [])]
            gitnexus_skills = [skill for skill in skill_rows if skill.get("name", "").startswith("gitnexus-")]
            admin_skills = [skill for skill in gitnexus_skills if skill.get("scope") == "admin"]
            assert len(admin_skills) == 12, \
                f"Codex discovered {len(admin_skills)}/12 admin GitNexus skills: " \
                f"{[(skill.get('name'), skill.get('scope')) for skill in gitnexus_skills]!r}"
            assert any(skill.get("name") == "gitnexus-exploring" and skill.get("scope") == "admin"
                       for skill in gitnexus_skills), f"Codex missed the admin skill root: {skills!r}"
            assert any(skill.get("name") == "gitnexus-cli" and skill.get("scope") == "user"
                       and "User override smoke fixture" in skill.get("description", "")
                       for skill in skill_rows), f"Codex did not select the user skill collision: {skills!r}"

            statuses = app.request("mcpServerStatus/list", {})
            server_rows = statuses.get("data", [])
            server = next((row for row in server_rows if row.get("name") == "gitnexus"), None)
            assert server is not None, f"Codex did not register GitNexus MCP: {statuses!r}"
            tool_rows = server.get("tools", [])
            assert ("query" in tool_rows if isinstance(tool_rows, dict) else
                    any(tool.get("name") == "query" for tool in tool_rows)), \
                f"Codex did not discover GitNexus query tool: {server!r}"

            thread = app.request("thread/start", {"cwd": str(repo), "ephemeral": True})
            thread_id = thread.get("thread", {}).get("id") or thread.get("data", {}).get("id") or thread.get("threadId")
            assert thread_id, f"Codex failed to start an ephemeral tool thread: {thread!r}"
            call = app.request("mcpServer/tool/call", {
                "server": "gitnexus",
                "threadId": thread_id,
                "tool": "query",
                "arguments": {"search_query": "target", "repo": str(repo), "response_sections": ["definitions"]},
            })
            assert not call.get("isError", False), f"Codex MCP tool call returned an error: {call!r}"
            content = call.get("content", [])
            assert content and content[0].get("type") == "text", \
                f"Codex MCP tool call returned no text result: {call!r}"
            try:
                call_result = json.loads(content[0]["text"])
            except json.JSONDecodeError as error:
                raise AssertionError(f"Codex MCP tool call returned non-JSON text: {content[0]!r}") from error
            call_definitions = call_result.get("definitions", [])
            assert any(item.get("name") == "target" and item.get("filePath") == "app.js"
                       for item in call_definitions if isinstance(item, dict)), \
                f"Codex MCP tool call did not return the indexed target definition: {call_result!r}"
            print("PASS Codex 0.172 app-server skills/list and MCP tool list/call")
        finally:
            app.close()
    finally:
        shutil.rmtree(home)


if __name__ == "__main__":
    main()
