# multica-workspace

在容器中运行 Multica 智能体（agent daemon）的镜像。

本仓库构建一个基于 Debian trixie 的镜像，预装 **opencode**、**hermes**、**multica** 三个 CLI 以及 **gstack**（Claude Code 技能集）运行环境，容器启动后前台拉起 `multica daemon`，作为一台“设备”接入 Multica 平台、自动领取并执行分配给你的任务。

- 镜像内容与安装细节见 [`Dockerfile`](./Dockerfile)
- 镜像由 CI 自动构建并推送到 GHCR，见 [`.github/workflows/docker-build.yml`](./.github/workflows/docker-build.yml)

---

## 快速开始（docker-compose）

### 1. 准备令牌

daemon 通过环境变量 `MULTICA_TOKEN` 认证。先在 Multica 平台生成一个令牌：

- **Cloud Node PAT**（`mcn_...`）—— 推荐，用于长期运行的 daemon 设备
- **用户 PAT**（`mul_...`）—— 也可使用

> ⚠️ 不要把令牌写死在 `docker-compose.yml` 里或提交到仓库。用 `.env` 文件或密钥管理系统注入。

### 2. 创建 `.env`

在仓库根目录创建 `.env`（建议加入 `.gitignore`，不要提交）：

```dotenv
# 必填：Multica 登录令牌
MULTICA_TOKEN=mcn_xxxxxxxxxxxxxxxxxxxxxxxx

# 可选：只监听指定工作区，留空则监听账号下全部工作区
MULTICA_WORKSPACE_ID=

# 可选：自托管服务器地址（默认 https://api.multica.ai）
# MULTICA_SERVER_URL=https://api.multica.ai
```

### 3. 创建 `docker-compose.yml`

```yaml
services:
  multica-agent:
    # 使用 CI 推送到 GHCR 的镜像；也可本地构建（见下方“本地构建”）
    image: ghcr.io/liling/multica-workspace:latest

    # 容器 HOSTNAME = 平台上显示的 daemon 设备名。
    # 起一个有辨识度的名字，方便在 Multica 平台识别这台设备。
    container_name: multica-agent-01
    hostname: multica-agent-01

    environment:
      # 必填：认证令牌（从 .env 注入，缺失则启动报错）
      MULTICA_TOKEN: ${MULTICA_TOKEN:?请在 .env 中设置 MULTICA_TOKEN}
      # 可选：绑定到某个工作区（留空监听全部）
      MULTICA_WORKSPACE_ID: ${MULTICA_WORKSPACE_ID:-}
      # 可选：自托管服务器时覆盖默认服务端地址
      # MULTICA_SERVER_URL: https://api.multica.ai
      # 可选：并行执行的最大任务数
      # MULTICA_DAEMON_MAX_CONCURRENT_TASKS: 2

    # 持久化状态，容器重建后不丢 daemon 身份、hermes 数据和工作区
    volumes:
      - multica-state:/root/.multica              # daemon id / 配置
      - hermes-state:/root/.hermes                # hermes 数据目录（HERMES_HOME）
      - agent-workspaces:/root/multica_workspaces # 任务工作区

    restart: unless-stopped

volumes:
  multica-state:
  hermes-state:
  agent-workspaces:
```

### 4. 启动

```bash
docker compose up -d        # 后台启动
docker compose logs -f      # 查看 daemon 日志
```

启动后，在 Multica 平台的设备列表里应能看到一台名为 `multica-agent-01` 的设备上线，之后分配给它的任务会被自动领取并执行。

停止 / 重启：

```bash
docker compose down         # 停止并移除容器（数据卷保留）
docker compose restart      # 重启
```

---

## 配置项说明

daemon 主要通过环境变量配置。常用项：

| 环境变量 | 必填 | 说明 |
|---|---|---|
| `MULTICA_TOKEN` | ✅ | 认证令牌（`mcn_...` Cloud Node PAT 或 `mul_...` 用户 PAT） |
| `MULTICA_WORKSPACE_ID` | | 绑定到指定工作区；留空监听账号下全部工作区 |
| `MULTICA_SERVER_URL` | | 服务端地址，默认 `https://api.multica.ai`；自托管时覆盖 |
| `MULTICA_DAEMON_DEVICE_NAME` | | daemon 设备名；镜像默认取容器 `HOSTNAME`（即 compose 里的 `hostname`） |
| `MULTICA_DAEMON_MAX_CONCURRENT_TASKS` | | 并行执行的最大任务数 |
| `MULTICA_DAEMON_POLL_INTERVAL` | | 任务轮询间隔 |
| `MULTICA_AGENT_TIMEOUT` | | 单任务墙钟时间上限（`0` 表示不限） |

> 更多标志见 `multica daemon start --help`（每个标志都有对应的 `env:` 环境变量）。

### 数据卷

镜像以 `root` 运行，默认数据目录如下，建议全部挂成命名卷以持久化：

| 路径 | 内容 |
|---|---|
| `/root/.multica` | daemon 身份（`daemon.id`）、CLI 配置 |
| `/root/.hermes` | hermes 数据目录（`HERMES_HOME`） |
| `/root/multica_workspaces` | 任务工作区（各任务的代码检出等） |

---

## 本地构建（可选）

若不想用 GHCR 上的镜像，可本地构建：把 compose 里的 `image:` 一行换成 `build:` 段，

```yaml
services:
  multica-agent:
    build:
      context: .
      dockerfile: Dockerfile
    # ...其余同上
```

然后：

```bash
docker compose up -d --build
```

或直接用 docker：

```bash
docker build -t multica-workspace:local .
docker run -d --name multica-agent-01 --hostname multica-agent-01 \
  -e MULTICA_TOKEN=mcn_xxxx \
  -v multica-state:/root/.multica \
  -v hermes-state:/root/.hermes \
  -v agent-workspaces:/root/multica_workspaces \
  --restart unless-stopped \
  multica-workspace:local
```

> 每次 `docker build` 会拉取当时最新的 opencode / hermes / multica；镜像本身不锁定版本号（如需锁定见 `Dockerfile` 顶部注释）。镜像支持 `linux/amd64` 与 `linux/arm64`。

---

## 常见问题

- **设备没上线 / 日志报未认证**：检查 `MULTICA_TOKEN` 是否正确注入（`docker compose exec multica-agent multica auth status`）。
- **想让一台机器跑多个 daemon**：复制一份 service，改成不同的 `container_name` / `hostname`，并使用各自独立的命名卷。
- **自托管服务器**：设置 `MULTICA_SERVER_URL` 指向你的服务端。
