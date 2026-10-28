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

镜像默认以 `multica`（UID/GID 1000）运行，HOME 和工作目录分别为 `/home/multica` 与 `/home/multica/multica_workspaces`。注入 `MULTICA_TOKEN`，并持久化 `/home/multica/.multica`、`/home/multica/.pi/agent`、`/home/multica/multica_workspaces` 与 `/home/multica/.ssh`：

```sh
docker run -d --name multica-agent --hostname multica-agent \
  -e MULTICA_TOKEN="$MULTICA_TOKEN" \
  -v multica-state:/home/multica/.multica \
  -v pi-agent:/home/multica/.pi/agent \
  -v agent-workspaces:/home/multica/multica_workspaces \
  -v ssh-keys:/home/multica/.ssh \
  ghcr.io/liling/multica-workspace:latest
```

Codex 可在容器内直接使用 `codex`。Chrome DevTools MCP 入口为 `chrome-devtools-mcp`; 示例：`npx -y chrome-devtools-mcp --help`。Chromium 可用于 headless/CDP 自动化。

Docker CLI 仅用于连接宿主机 Docker；不应在容器内启动 Docker daemon。需要时挂载宿主 socket：

```sh
-v /var/run/docker.sock:/var/run/docker.sock
```

显式挂载时，按宿主机 socket 的 GID 为容器增加 supplementary group，例如 `--group-add <socket-gid>`。Docker socket 基本等同宿主机 root 权限；只对可信工作负载挂载，并避免暴露给不可信 agent/task。镜像不预设 docker group，也不修改 socket 权限。

## Breaking migration 与权限风险

此版本将运行用户从 root 改为 UID/GID 1000 的 `multica`，属于 breaking migration。旧容器将卷挂载到 `/root/.multica`、`/root/.pi/agent`、`/root/.ssh` 或 `/root/multica_workspaces` 时，必须把挂载目标改为对应的 `/home/multica/...` 路径；迁移现有数据时请在宿主机备份并调整卷所有权为 UID/GID 1000。镜像不会在 `/root` 建立可写兼容回退。

`multica` 可使用 `/etc/sudoers.d/multica` 中配置的免密码 `sudo`。默认启动进程仍是 UID 1000，但容器内用户可随时取得 root；因此非 root 默认运行可降低意外 root 进程风险，不构成强权限隔离。不要将其视为对抗容器内不可信代码的安全边界。

## 构建与测试

```sh
bash tests/supervisor.sh
bash tests/image-contract.sh
```

项目正式验收由 GitHub Actions 执行 amd64/arm64 构建。不要在本地执行 Docker build 作为验收证据。两架构都使用 Debian trixie Chromium 包及 Node/npm 的架构原生构建，构建阶段会校验 CLI、sudo 权限及目录属主/权限。
