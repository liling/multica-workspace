# multica-workspace

Multica 编程 Agent 工作站，支持 `linux/amd64` 与 `linux/arm64`。项目采用“两段式构建”，把必须访问 GitHub 的 Multica CLI 与适合在国内服务器安装/更新的软件环境彻底分开。

## 构建模型

### 1. GitHub Actions：bootstrap 镜像

`Dockerfile.bootstrap` 负责从 GitHub Release 获取固定版本的 Multica CLI。当前 GitHub Actions 固定使用 Multica CLI `0.8.1`，并发布多架构基础镜像：

```text
ghcr.io/liling/multica-workspace-bootstrap:0.8.1
```

版本号直接写在 `.github/workflows/docker-build.yml` 的 `MULTICA_VERSION` 中。需要升级 Multica CLI 时，明确修改该版本号后重新构建，不再自动跟随 `latest`。服务器不调用 GitHub Release API，也不直接下载 Multica Release 文件。

### 2. 服务器：workspace 镜像

`Dockerfile` 基于 bootstrap 镜像，在服务器侧安装工作站软件。国内源优先使用 TUNA：

- Debian：`https://mirrors.tuna.tsinghua.edu.cn/debian`
- Debian Security：`https://mirrors.tuna.tsinghua.edu.cn/debian-security`
- Node.js：`https://mirrors.tuna.tsinghua.edu.cn/nodejs-release`
- npm registry：TUNA 没有对应 registry，使用 `https://registry.npmmirror.com`

最终镜像包含已固定版本的 Codex Stop Guard vNext、Node.js 24/npm、Multica CLI、pi、Codex CLI、Git、GitHub CLI、Docker CLI、Chromium、Chrome DevTools MCP、Python 3、jq、pnpm、build-essential、tini、curl、wget、openssh-client、vim、ripgrep、fd-find、host/dig/nslookup、ping、ip/ss、nc 与 traceroute。

为避免影响正在运行的工作站，现有 `Dockerfile`、`compose.yaml` 与 `.env.example` 仍默认使用 `0.7.1`。如需在服务器侧构建包含 CLI `0.8.1` 的最终工作站镜像，请在 `.env` 中显式设置 `BOOTSTRAP_IMAGE=ghcr.nju.edu.cn/liling/multica-workspace-bootstrap:0.8.1`，再运行 `docker compose build --pull agent && docker compose up -d agent`。首次构建前应确保新镜像已在 GHCR 发布并且代理同步可用。

现有部署默认 bootstrap 地址使用南京大学 GHCR 代理：

```text
ghcr.nju.edu.cn/liling/multica-workspace-bootstrap:0.7.1
```

如果部署环境可稳定访问 GHCR，可通过 `.env` 改为 `ghcr.io/liling/multica-workspace-bootstrap:0.7.1`。

## 启动与更新

复制环境变量模板：

```sh
cp .env.example .env
```

至少填写 `MULTICA_TOKEN`。首次启动或代码发生变化时：

```sh
docker compose up -d --build
```

Compose 会在服务器上构建最终 workspace 镜像。软件安装发生在 Docker build 阶段，而不是容器 entrypoint；普通容器重启不会联网安装软件。

需要主动刷新 bootstrap、APT、Node 和 npm 安装层时运行：

```sh
./scripts/update.sh
```

该脚本使用 `docker compose build --pull --no-cache`，然后重新启动服务。这样“更新软件”和“运行服务”是两个明确的生命周期。

## Codex Stop Guard vNext（默认启用）

镜像在 **Docker build** 阶段内置已验收的 [Multica Agent Playbook Guard](https://github.com/liling/multica-agent-playbook/tree/db313fa2df91fdf9c267c9354741cde51fd9ac65/tools/run-identity-optin)，固定来源提交：

```text
db313fa2df91fdf9c267c9354741cde51fd9ac65 (MEM-773 / Playbook PR #50)
```

`guard-vnext/` 下五个 Python 运行文件与该提交 **Git Blob SHA 完全一致**，由 `guard-vnext/source-manifest.txt` 和 `tests/guard-contract.sh` 守护。版本更新需要显式替换文件、更新 SHA 和测试，**不会自动跟随 Playbook 的 main**。

- 文件安装在 `/etc/codex/hooks/guard-vnext/`，由系统级 `/etc/codex/config.toml` 注册 `Stop` Command Hook（`timeout = 8`）。
- 系统配置不受持久卷 `/home/multica/.codex` 覆盖，原有 Codex 用户配置及 token 不会被改写；Codex 会组合多个配置层的 hooks，如果个人配置也注册同一 Stop Guard，**应删除重复的个人 hook**，避免同一 Stop 被重复检查。
- 缺少可信 UEP 反馈时，对相同 Run/turn 最多执行三次 `block`，第四次 `retry_exhausted_allow`；平台权威的当前 Run `no_action` 或有效 UEP 反馈直接放行；身份不可信、查询超时或数据不完整时仍 fail-open。
- 状态数据库 `/home/multica/.multica/guard-stop-budget.sqlite3`、观察日志 `/home/multica/.multica/guard-vnext-shadow.jsonl` 位于已有 `multica-state` 持久卷内。脚本不含模型调用、不对 Multica 发写入请求。
- 此处是 **Linux 容器的安装方案**，不是 Mac 的 `sudo` 一次性安装脚本；镜像构建不访问 GitHub，也不触碰宿主机 `/etc/codex`。

重新构建并重建容器才能生效：

```sh
docker compose up -d --build
docker compose exec agent sh -lc 'cat /etc/codex/config.toml; ls -l /etc/codex/hooks/guard-vnext'
docker compose exec agent sh -lc 'tail -n 15 ~/.multica/guard-vnext-shadow.jsonl'
```

最后一条命令需要至少一次实际 Codex Stop 后才会有日志。构建只检验安装与 Hook 合同，**不代表已完成容器内真实 Multica Run E2E**。若需要在个人 `~/.codex/config.toml` 配置额外 hooks，请检查是否与系统级 Stop Hook 重复。

## 生命周期语义

容器始终由 tini 与 entrypoint supervisor 保持运行。容器 `Running` 表示工作站可进入和诊断；容器 `Healthy` 表示 Multica daemon 正常在线。缺少令牌、认证失败或 daemon 异常时容器保持运行并报告 `unhealthy`，并按退避策略重试。

状态位于 `/run/multica-workspace/`：`status`、`daemon.pid`、`last-error`。排障可运行：

```sh
docker compose exec agent cat /run/multica-workspace/status
docker compose exec agent cat /run/multica-workspace/last-error
docker compose logs agent
```

默认运行用户为 `multica`（UID/GID 1000），HOME 为 `/home/multica`，工作目录为 `/home/multica/multica_workspaces`。持久卷覆盖 Multica、pi、Codex、gh、SSH 与 Agent workspace 状态。

## Docker socket

镜像只包含 Docker CLI，不在容器内运行 Docker daemon。如果 Agent 需要操作宿主 Docker，可以额外挂载：

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock
group_add:
  - "${DOCKER_GID}"
```

在宿主机设置：

```sh
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
```

再把该值写入部署用 `.env`。Docker socket 基本等同宿主机 root 权限，只应提供给可信工作负载。

## 测试

```sh
bash tests/supervisor.sh
bash tests/image-contract.sh
bash tests/guard-contract.sh
```

构建后的最终镜像还可以执行：

```sh
bash tests/container-smoke.sh multica-workspace:local
```

`tests/image-contract.sh` 会确保 GitHub Release 下载只存在于 bootstrap Dockerfile，服务器侧 Dockerfile 使用 TUNA/npmmirror，并保留 UID 1000、sudo、healthcheck 与 supervisor 运行契约。
