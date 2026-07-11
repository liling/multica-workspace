#!/usr/bin/env bash
# gstack-install.sh — 在 Debian/Ubuntu 容器里安装 gstack 及其运行环境
# 幂等。已验证于 Debian 12 (bookworm)。用法: bash gstack-install.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
GSTACK_REPO_URL="${GSTACK_REPO_URL:-https://github.com/garrytan/gstack.git}"
GSTACK_CLONE_DIR="${GSTACK_CLONE_DIR:-$HOME/.claude/skills/gstack}"
BUN_INSTALL_DIR="${BUN_INSTALL_DIR:-/usr/local/lib/bun}"
HOST="${GSTACK_HOST:-claude}"

echo "==> [1/6] 系统依赖"
apt-get update -qq
apt-get install -y -qq unzip fonts-noto-color-emoji libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libasound2 libatspi2.0-0 fonts-liberation fonts-freefont-ttf xvfb

echo "==> [2/6] 安装 Bun"
if command -v bun >/dev/null 2>&1; then echo "    bun 已存在: $(bun --version)"; else
  curl -fsSL https://bun.sh/install | BUN_INSTALL="$BUN_INSTALL_DIR" bash
  ln -sf "$BUN_INSTALL_DIR/bin/bun" /usr/local/bin/bun
  ln -sf "$BUN_INSTALL_DIR/bin/bunx" /usr/local/bin/bunx
  echo "    bun: $(bun --version)"
fi
export PATH="$BUN_INSTALL_DIR/bin:$PATH"

echo "==> [3/6] 检查 node / git"
command -v node >/dev/null 2>&1 || { echo "ERROR: node 未安装"; exit 1; }
command -v git  >/dev/null 2>&1 || { echo "ERROR: git 未安装"; exit 1; }

echo "==> [4/6] 克隆 gstack"
if [ -d "$GSTACK_CLONE_DIR/.git" ]; then git -C "$GSTACK_CLONE_DIR" pull --ff-only --quiet 2>/dev/null || true;
else mkdir -p "$(dirname "$GSTACK_CLONE_DIR")"; git clone --single-branch --depth 1 "$GSTACK_REPO_URL" "$GSTACK_CLONE_DIR"; fi

echo "==> [5/6] 运行 setup"
cd "$GSTACK_CLONE_DIR"
export GSTACK_SKIP_FONTS=1
./setup --host "$HOST" -q --no-prefix

echo "==> [6/6] 验证 Chromium"
cd "$GSTACK_CLONE_DIR"
bun --eval 'import { chromium } from "playwright"; (async () => { const b = await chromium.launch(); await b.close(); console.log("    chromium launch OK"); })().catch(e => { console.error("    FAILED:", e.message); process.exit(1); })'
echo "✅ gstack 环境安装完成: $GSTACK_CLONE_DIR"
