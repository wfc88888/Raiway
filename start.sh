#!/bin/bash
set -eu

TOKEN_PLACEHOLDER="PASTE_YOUR_CLOUDFLARE_TUNNEL_TOKEN_HERE"
ARGO_TOKEN="${ARGO_TOKEN:-}"

if [ -z "${ARGO_TOKEN}" ] || [ "${ARGO_TOKEN}" = "${TOKEN_PLACEHOLDER}" ]; then
  echo "Error: ARGO_TOKEN is missing. 请在部署平台填写环境变量。"
  exit 1
fi

# ==========================================
# 内置稳定心跳保活 (Built-in Stable Heartbeat)
# 彻底抛弃第三方 API，通过持续的内部与外部极轻量级请求保持容器 24 小时活跃
# ==========================================
echo "Starting Built-in Stable Keep-Alive Daemon..."
(
  while true; do
    # 1. 内部活跃：唤醒本地 Caddy 进程，防止系统判定进程休眠
    curl -s http://127.0.0.1:8080/ >/dev/null 2>&1 || true
    
    # 2. 外部活跃：向 Cloudflare 官方探针发送请求，维持网络 I/O 活跃
    curl -s https://1.1.1.1/cdn-cgi/trace >/dev/null 2>&1 || true
    
    # 每隔 10 分钟 (600秒) 模拟一次呼吸
    sleep 600
  done
) &

echo "Starting proxy services (Xray + Caddy)..."

# 启动核心与前置分流
/usr/bin/xray/xray run -c /etc/xray/config.json &
caddy start --config /etc/caddy/Caddyfile --adapter caddyfile

# 启动 CF 隧道阻断前台，承接公网流量
echo "Connecting to Cloudflare Tunnel..."
/usr/bin/cloudflared tunnel --no-autoupdate run --token "${ARGO_TOKEN}"
