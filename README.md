# multica-workspace

Multica 编程 Agent 工作站，支持 `linux/amd64` 与 `linux/arm64`。项目采用“两段式构建”，把必须访问 GitHub 的 Multica CLI 与适合在国内服务器安装/更新的软件环境彻底分开。

## 构建模型

### 1. GitHub Actions：bootstrap 镜像

`Dockerfile.bootstrap` 负责从 GitHub Release 获取固定版本的 Multica CLI。当前 GitHub Actions 固定使用 Multica CLI `0.7.1`，并发布多架构基础镜像：

```text
ghcr.io/liling/multica-workspace-bootstrap:0.7.1
```

版本号直接写在 `.github/workflows/docker-build.yml` 的 `MULTICA_VERSION` 中。需要升级 Multica CLI 时，明确修改该版本号后重新构建，不再自动跟随 `latest`。服务器不调用 GitHub Release API，也不直接下载 Multica Release 文件。

### 2. 服务器：workspace 镜像

`Dockerfile` 基于 bootstrap 镜像，在服务器侧安装工作站软件。国内源优先使用 TUNA：

- Debian：`https://mirrors.tuna.tsinghua.edu.cn/debian`
- Debian Security：`https://mirrors.tuna.tsinghua.edu.cn/debian-security`
- Node.js：`https://mirrors.tuna.tsinghua.edu.cn/nodejs-release`
- npm registry：TUNA 没有对应 registry，使用 `https://registry.npmmirror.com`

最终镜像包含 Node.js 24/npm、Multica CLI、pi、Codex CLI、Git、GitHub CLI、Docker CLI、Chromium、Chrome DevTools MCP、Python 3、jq、pnpm、build-essential、tini、curl、wget、openssh-client、vim、ripgrep、fd-find、host/dig/nslookup、ping、ip/ss、nc 与 traceroute。

默认 bootstrap 地址使用南京大学 GHCR 代理：

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
```

构建后的最终镜像还可以执行：

```sh
bash tests/container-smoke.sh multica-workspace:local
```

`tests/image-contract.sh` 会确保 GitHub Release 下载只存在于 bootstrap Dockerfile，服务器侧 Dockerfile 使用 TUNA/npmmirror，并保留 UID 1000、sudo、healthcheck 与 supervisor 运行契约。
