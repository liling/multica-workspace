# multica-workspace

基于 Debian trixie 的 Multica 编程 Agent 工作站镜像，支持 `linux/amd64` 与 `linux/arm64`。镜像包含 Node.js 24/npm、Multica CLI、pi、Codex CLI、Git、GitHub CLI、Docker CLI、Chromium、Chrome DevTools MCP、Python 3、jq、pnpm、build-essential、tini、curl、openssh-client、vim、ripgrep 与 fd-find。

## 生命周期语义

容器始终由 tini 与 entrypoint supervisor 保持运行。容器 `Running` 表示工作站可进入和诊断；容器 `Healthy` 表示 Multica daemon 正常在线。缺少令牌、认证失败或 daemon 异常时容器保持运行并报告 `unhealthy`，以 5、15、45、60 秒（之后最多每 60 秒）退避重试。已有持久化认证有效时不会重复 login；daemon 稳定存活后重试间隔复位。

状态位于 `/run/multica-workspace/`：`status`、`daemon.pid`、`last-error`。排障可运行：

```sh
docker exec <container> cat /run/multica-workspace/status
docker exec <container> cat /run/multica-workspace/last-error
docker logs <container>
```

SIGTERM（`docker stop`）会转发到 daemon 并清理 PID 文件。调试可用 `docker run --rm <image> bash` 或 `MULTICA_DEBUG_SHELL=1`。

## 启动

注入 `MULTICA_TOKEN`，并建议持久化 `/root/.multica`、`/root/.pi/agent`、`/root/multica_workspaces` 与 `/root/.ssh`：

```sh
docker run -d --name multica-agent --hostname multica-agent \
  -e MULTICA_TOKEN="$MULTICA_TOKEN" \
  -v multica-state:/root/.multica \
  -v pi-agent:/root/.pi/agent \
  -v agent-workspaces:/root/multica_workspaces \
  -v ssh-keys:/root/.ssh \
  ghcr.io/liling/multica-workspace:latest
```

Codex 可在容器内直接使用 `codex`。Chrome DevTools MCP 入口为 `chrome-devtools-mcp`; 示例：`npx -y chrome-devtools-mcp --help`。Chromium 可用于 headless/CDP 自动化。

Docker CLI 仅用于连接宿主机 Docker；不应在容器内启动 Docker daemon。需要时挂载宿主 socket：

```sh
-v /var/run/docker.sock:/var/run/docker.sock
```

警告：Docker socket 基本等同宿主机 root 权限；只对可信工作负载挂载，并避免暴露给不可信 agent/task。

## 构建与测试

```sh
docker build --build-arg MULTICA_VERSION=v0.6.1 -t multica-workspace:local .
bash tests/supervisor.sh
```

跨架构复现（需 Docker Buildx 与可用的 QEMU/binfmt）：

```sh
docker buildx build --platform linux/amd64,linux/arm64 --build-arg MULTICA_VERSION=v0.6.1 --tag multica-workspace:check --load .
```

若本机不能执行两种架构，可通过注册 QEMU 后在支持 Buildx 的 Linux 主机执行；两架构都使用 Debian trixie Chromium 包及 Node/npm 的架构原生构建，构建期逐项校验可执行入口。不能用 `--load` 加载多平台镜像时，移除 `--load` 并使用 `--push` 推至临时 registry。
