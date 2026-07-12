# multica-workspace

在容器中运行 Multica 智能体（agent daemon）的镜像。

本仓库构建一个基于 Debian trixie 的镜像，预装 **pi**、**hermes**、**multica** 三个 CLI，并通过 `pi install npm:pi-subagents` / `pi install npm:pi-gstack` 把 Garry Tan 的 **gstack**（Claude Code 风格技能集）以 pi 扩展形式适配进 pi（命名空间 `/gstack-*`），同时附带 **openssh-client**（便于 git+ssh / 远程登录）与 **GitHub CLI（`gh`）**（便于在容器内直接操作 GitHub：PR / issue / workflow 等），容器启动后前台拉起 `multica daemon`，作为一台“设备”接入 Multica 平台、自动领取并执行分配给你的任务。容器默认工作目录为 `/root/multica_workspaces`，SSH 密钥目录 `/root/.ssh` 建议通过卷持久化（见下方「数据卷」）。

- 镜像内容与安装细节见 [`Dockerfile`](./Dockerfile)
- 镜像由 CI 自动构建并推送到 GHCR，见 [`.github/workflows/docker-build.yml`](./.github/workflows/docker-build.yml)

---

## 快速开始（docker-compose）

### 1. 准备令牌

daemon 通过 `multica login` 固化到 `~/.multica/config.json` 的登录态来认证；而 **`MULTICA_TOKEN`** 这个环境变量，是首次启动时把令牌交给 `multica login` 完成固化的来源。先在 Multica 平台生成一个令牌：

- **Cloud Node PAT**（`mcn_...`）—— 推荐，用于长期运行的 daemon 设备
- **用户 PAT**（`mul_...`）—— 也可使用

> ⚠️ 不要把令牌写死在 `docker-compose.yml` 里或提交到仓库。用 `.env` 文件或密钥管理系统注入。

### 2. 创建 `.env`

在**与 `docker-compose.yml` 同一目录**下创建 `.env`（建议加入 `.gitignore`，不要提交）：

```dotenv
# 必填：Multica 登录令牌（首次启动由 entrypoint 交给 multica login 固化到 config.json）
MULTICA_TOKEN=mcn_xxxxxxxxxxxxxxxxxxxxxxxx

# 可选：只监听指定工作区，留空则监听账号下全部工作区
MULTICA_WORKSPACE_ID=

# 可选：自托管服务器地址（默认 https://api.multica.ai）
# MULTICA_SERVER_URL=https://api.multica.ai
```

> 注意：`.env` 必须是 `KEY=VALUE` 形式，**不要**带 `export` 前缀，也**不要**用引号包裹（如 `MULTICA_TOKEN="..."` 会让引号本身也变成令牌的一部分）。
> 关键点：`docker compose` 只会自动加载**与 compose 文件同目录**的 `.env`。若 `.env` 放在别的目录，令牌不会被注入，容器就会一直报 `not authenticated: run 'multica login' first`。

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

    # 通过 env_file 把同目录的 .env 注入容器（含 MULTICA_TOKEN）。
    # 这是 daemon 拿到认证令牌的可靠方式。
    env_file:
      - .env

    environment:
      # 可选：绑定到某个工作区（留空监听全部）
      MULTICA_WORKSPACE_ID: ${MULTICA_WORKSPACE_ID:-}
      # 可选：自托管服务器时覆盖默认服务端地址
      # MULTICA_SERVER_URL: https://api.multica.ai
      # 可选：并行执行的最大任务数
      # MULTICA_DAEMON_MAX_CONCURRENT_TASKS: 2

    # 持久化状态，容器重建后不丢 daemon 身份、各 CLI 配置/凭据和工作区
    volumes:
      - multica-state:/root/.multica                    # daemon id / multica 配置
      - hermes-state:/root/.hermes                      # hermes 数据目录（HERMES_HOME）
      # pi 的配置 / 凭据 / 会话集中在 ~/.pi/agent/，建议持久化：
      - pi-agent:/root/.pi/agent                        # 配置、凭据 auth.json、会话 DB、日志
      - agent-workspaces:/root/multica_workspaces       # 任务工作区
      - ssh-keys:/root/.ssh                          # SSH 密钥（见 MEM-12，需持久化）

    restart: unless-stopped

volumes:
  multica-state:
  hermes-state:
  pi-agent:
  agent-workspaces:
  ssh-keys:
```

> **为什么用 `env_file` 而不是直接在 `environment:` 里写 `MULTICA_TOKEN: ${MULTICA_TOKEN:?...}`？**
> 两种方式都行。但后者依赖“运行 `docker compose` 的 shell 自己已经 `export` 了 `MULTICA_TOKEN`”，容易因为变量没导出、或在别处执行而拿到空值，进而触发 `not authenticated`。用同目录的 `.env` + `env_file` 最省心、首次启动即可用。

> **关于 pi 的配置目录**：pi 把配置、凭据、会话、扩展等数据集中存放在 `~/.pi/agent/` 目录下，
> 其中最关键的是该目录下的 `auth.json`（保存各 provider 的登录凭据）。建议把 `/root/.pi/agent`
> 通过卷持久化（见 compose 示例），否则容器重建后 pi 会丢失登录、需要重新 `/login`。
> 与 opencode 不同，pi 不需要分散挂载 XDG 多处——单个卷即可覆盖全部状态。

### 4. 启动

```bash
docker compose up -d        # 后台启动
docker compose logs -f      # 查看 daemon 日志
```

容器启动后，`entrypoint.sh` 会先检查 `MULTICA_TOKEN` 是否已注入：
- **缺令牌**：直接以非零状态退出，日志里明确提示“未设置 MULTICA_TOKEN”，不会静默一直报 `not authenticated`。
- **有令牌但未登录**：自动用 `MULTICA_TOKEN` 执行 `multica login --token` 固化登录态（写入 config.json 的 token 字段，daemon 实际读取的就是这里）；**执行 login 之前会先完成 `server_url` / `app_url` 配置**（默认官方地址，可用 `MULTICA_SERVER_URL` / `MULTICA_APP_URL` 覆盖），避免 `login` 报 “No server configured”。若令牌无效则直接报错退出，不再带病启动。

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
| `MULTICA_TOKEN` | ✅ | 认证令牌（`mcn_...` Cloud Node PAT 或 `mul_...` 用户 PAT）。首次启动由 entrypoint 交给 `multica login` 固化到 config.json，daemon 读取该固化态 |
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
| `/root/.multica` | multica daemon 身份（`daemon.id`）、CLI 配置 |
| `/root/.hermes` | hermes 数据目录（`HERMES_HOME`） |
| `/root/.pi/agent` | pi 配置 / 凭据 `auth.json` / 会话 / 扩展等全部状态（**最关键，勿丢**） |
| `/root/.ssh` | SSH 密钥（`id_rsa` 等），容器重建后仍需保留（见 MEM-12） |
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
  --env-file .env \
  -v multica-state:/root/.multica \
  -v hermes-state:/root/.hermes \
  -v pi-agent:/root/.pi/agent \
  -v agent-workspaces:/root/multica_workspaces \
  --restart unless-stopped \
  multica-workspace:local
```

> 每次 `docker build` 会拉取当时最新的 pi / hermes / multica；镜像本身不锁定版本号（如需锁定见 `Dockerfile` 顶部注释）。镜像支持 `linux/amd64` 与 `linux/arm64`。

---

## 常见问题

- **设备没上线 / 日志报 `not authenticated`**：先确认 `MULTICA_TOKEN` 已注入容器（见下方验证命令）。若已注入仍报错，多半是令牌本身无效或过期——`entrypoint.sh` 现在会在 `multica login --token` 失败时直接以非零状态退出并打印服务端返回的错误，按提示更换有效令牌即可。
  ```bash
  docker compose exec multica-agent printenv MULTICA_TOKEN
  # 应能看到你的 mcn_... / mul_... 令牌；若为空，说明 .env 没被加载
  docker compose exec multica-agent multica auth status
  # 应显示已登录（Logged in as ...）；若显示 not authenticated，说明令牌无效/过期
  docker compose exec multica-agent multica workspace list
  # 能列出工作区即说明认证成功
  ```
  如果 `printenv` 为空但 `docker compose up` 没报错，通常是 `.env` 放错目录、或 `.env` 里用了 `export`/引号导致值解析异常。
- **想让一台机器跑多个 daemon**：复制一份 service，改成不同的 `container_name` / `hostname`，并使用各自独立的命名卷。
- **自托管服务器**：设置 `MULTICA_SERVER_URL` 指向你的服务端。


## 调试 / 进入容器

entrypoint 默认会把 multica daemon 设为容器的 PID 1 并常驻运行，但你随时可以进到容器里手工调试：

- **运行期间直接 exec**（最常用，不经过 entrypoint）：
  ```bash
  docker exec -it <容器名> bash
  ```
- **首次启动就进 shell、不拉 daemon**，用命令覆盖：
  ```bash
  docker compose run --rm <svc> bash
  # 或
  docker run --rm <镜像> bash
  ```
- **即使没配 `MULTICA_TOKEN` 也能进 shell**排查环境，设调试开关：
  ```bash
  docker run -e MULTICA_DEBUG_SHELL=1 <镜像> bash
  ```
  设了 `MULTICA_DEBUG_SHELL=1` 时，entrypoint 会跳过认证与 daemon，直接给出交互 shell。

进 shell 后可手动操作：`multica login --token <令牌>`、`cat ~/.multica/config.json`、`multica auth status`、`printenv MULTICA_TOKEN` 等，方便定位认证或网络问题。
