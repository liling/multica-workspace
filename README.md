# multica-workspace

Multica 编程 Agent 工作站，支持 `linux/amd64` 与 `linux/arm64`。项目采用“两段式构建”，把必须访问 GitHub 的 Multica CLI 与适合在国内服务器安装/更新的软件环境彻底分开。

## 构建模型

### 1. GitHub Actions：bootstrap 镜像

`Dockerfile.bootstrap` 仅从 GitHub Release 获取固定版本的 Multica CLI `0.13.0`、Hermes `v0.23.4` 固定源码归档（commit `8fc0374447313e276f6b9a2764bfc750190c966a`，SHA-256 `620bf64a63c7fabd995df402e46d5eee0cdab7e5d01a4aeddc3a6fa5dee54cc0`），以及固定版本的 CPython `3.14.10` python-build-standalone `install_only` 压缩包。它不包含 Hermes venv、常规 PyPI wheel、Node、浏览器或依赖缓存。发布的新 bootstrap 标签为：

```text
ghcr.io/liling/multica-workspace-bootstrap:0.13.0-hermes-0.23.4
```

Multica amd64/arm64 release 压缩包、Hermes commit archive、CPython amd64/arm64 `install_only` 压缩包均在 bootstrap 构建时校验 SHA-256。旧标签不覆盖。境外资源只出现在 GitHub Actions bootstrap 构建期间；服务器只拉取 bootstrap 镜像，不访问 GitHub。

### 2. 服务器：workspace 镜像

`Dockerfile` 基于 bootstrap 镜像，在服务器侧安装工作站软件。Hermes 需要 Python `>=3.14,<3.15`；本方案固定 CPython `3.14.10`，从 bootstrap 中已校验的 `install_only` 压缩包解压，不重复下载或编译 Python。uv `0.13.5` 与 Linux ACP Python 依赖从 TUNA PyPI 安装，不允许 uv 自动下载 Python。依赖版本与 hashes 由 Hermes `uv.lock` 固定；导出使用 `--frozen`，并忽略 `psutil` 的 source override 后排除 Android-only Git dependency（commit `380bd2b59c67b0e1b04bbf3a90b11744f4f96644`）。上游 uv 的 3-day `exclude-newer` 在部分镜像缺失上传时间时会把锁定 ACP 包判为过新，因此仅构建副本禁用该时间过滤；`--frozen` 和安装时 `--require-hashes` 仍约束锁定内容。可选 KittenTTS wheel/misaki Git source 未选择，不进入镜像。

服务器侧安装源：

- Debian：`https://mirrors.tuna.tsinghua.edu.cn/debian`
- Debian Security：`https://mirrors.tuna.tsinghua.edu.cn/debian-security`
- Node.js：`https://mirrors.tuna.tsinghua.edu.cn/nodejs-release`
- npm registry：TUNA 没有对应 registry，使用 `https://registry.npmmirror.com`
- PyPI：`https://pypi.tuna.tsinghua.edu.cn/simple`

最终镜像包含 Hermes `v0.23.4` Python 源码与 ACP/core 依赖、Multica CLI `0.13.0`、Codex Stop Guard vNext、Node.js 24/npm、pi、Codex CLI、Git、GitHub CLI、Docker CLI、系统 Chromium、Chrome DevTools MCP、Python 3.14.10、jq、pnpm、build-essential、tini、curl、wget、openssh-client、vim、ripgrep、fd-find、host/dig/nslookup、ping、ip/ss、nc 与 traceroute。

境外资源清单：Multica `v0.13.0` 官方 release（双架构 tarball，无可用国内官方镜像）、Hermes `v0.23.4` commit 归档（无国内镜像，且 tag→commit 固定需原始 Git 归档）、python-build-standalone `20261124` CPython `3.14.10` install_only 压缩包（国内镜像无法稳定保留固定历史 release，按用户授权放入 bootstrap）。它们仅在 bootstrap 构建时下载并校验；Debian、Node、npm、PyPI 均走国内镜像。

体积验收（amd64）：原完整 Hermes bootstrap 本地为 3,341,197,018 bytes 未压缩；旧 OCI image archive 的压缩 blob 合计 1,197,201,822 bytes。精简源码阶段记录为 250,400,856 bytes 未压缩；加入 Python 后本次 bootstrap 本地为 327,105,201 bytes 未压缩，Python 压缩归档为 76,700,449 bytes。新 OCI image archive 为 171,084,288 bytes（压缩 blob 合计 171,075,155 bytes），对比旧压缩 blob 减少约 85.7%，未压缩 image size 减少约 90.2%。这是可复现的本地 OCI 下载体积，不是 GHCR 远程 manifest 实测；尚未发布。amd64 最终 workspace 镜像为 3,468,255,687 bytes 未压缩，完整 container smoke 通过。为完成本地验证，本机 TUNA PyPI/Debian/Node HTTPS 出现 TLS EOF/证书错误，构建分别临时覆盖为 Aliyun PyPI/Debian 与 npmmirror Node；生产默认仍为 TUNA/npmmirror。arm64 Python 归档为 58,939,713 bytes（压缩文件），镜像构建未验证。

新配置默认使用新 bootstrap 标签。升级时先备份 `.env`；若现存 `.env` 明确设置了旧 `BOOTSTRAP_IMAGE`（如 `0.8.1`），将其更新为下方新标签，因为显式旧值会覆盖 Compose 默认值。确保新 bootstrap 标签已发布且代理同步完成，再构建并启动：

```sh
# 新版 Multica + Hermes
export BOOTSTRAP_IMAGE=ghcr.nju.edu.cn/liling/multica-workspace-bootstrap:0.13.0-hermes-0.23.4
docker compose build --pull agent && docker compose up -d agent
```

不能只把 `BOOTSTRAP_IMAGE` 改回 `0.8.1` 再用当前 `Dockerfile` 构建：旧 bootstrap 不含 Python standalone 包或 Hermes 源码。升级前应给当前最终镜像打一个本地回滚标签（下例 image 名须与 `.env` 中 `MULTICA_WORKSPACE_IMAGE` 一致；默认值为 `multica-workspace:local`）：

```sh
docker image tag multica-workspace:local multica-workspace:rollback
# 升级完成后如需回滚，保留所有卷，仅改用升级前的最终镜像：
printf '\nMULTICA_WORKSPACE_IMAGE=multica-workspace:rollback\n' >> .env
docker compose up -d --no-build agent
```

回滚不删除或重建任何命名卷；不要运行 `docker compose down -v`。若旧最终镜像未预先保留，则用升级前的源码版本（包含对应 `Dockerfile`、`compose.yaml` 与配置）和旧 bootstrap `ghcr.nju.edu.cn/liling/multica-workspace-bootstrap:0.8.1` 重建，不能混用本次新 Dockerfile。旧 bootstrap tag 保留，不覆盖。

如果部署环境可稳定访问 GHCR，可通过 `.env` 将 registry 域名改为 `ghcr.io`。

Hermes 用户配置、凭证与本机状态位于命名卷 `hermes-state`（`/home/multica/.hermes`，UID/GID 1000）；Hermes 可执行文件留在镜像 `/opt/hermes`，更新镜像不会覆盖该卷。Multica 0.13.0 将每个 Hermes Agent 的跨 Run memory 和 ACP session 分别存入既有 `multica-state` 卷下的 Hermes profile store；Hermes task overlay 将配置/凭证通过链接复用，任务级 skills 与 session 环境由 Multica 管理。因此 `hermes-state` 不是 Agent memory 卷。entrypoint 清除上游容器的 `/opt/data` 环境默认值，让 Hermes/Multica 在任务环境中自行解析 HOME/overlay，不启动 Hermes Gateway。

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

镜像在 **Docker build** 阶段内置指定版本的 [Multica Agent Playbook Guard](https://github.com/liling/multica-agent-playbook/tree/f53beffb29638e324fd7b264a305ebd5a009503e/tools/run-identity-optin)，固定来源提交：

```text
f53beffb29638e324fd7b264a305ebd5a009503e (UEP-K4 兼容升级候选 / Playbook PR #52)
```

`guard-vnext/` 下五个 Python 运行文件与该提交 **Git Blob SHA 完全一致**，由 `guard-vnext/source-manifest.txt` 和 `tests/guard-contract.sh` 守护。版本更新需要显式替换文件、更新 SHA 和测试，**不会自动跟随 Playbook 的 main**。

当前新版本仅在 PR 中准备，**尚未合并、构建镜像或安装运行时 Guard**。该版本对 UEP-K3 旧顺序与 UEP-K4 新顺序同时兼容；等实际 Guard 验证通过后，再统一切换 Agent 提示词。

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
