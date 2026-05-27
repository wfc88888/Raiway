#!/bin/bash
set -u

TOKEN_PLACEHOLDER="PASTE_YOUR_CLOUDFLARE_TUNNEL_TOKEN_HERE"
ARGO_TOKEN="${ARGO_TOKEN:-}"
RESTART_DELAY="${RESTART_DELAY:-5}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-60}"
HEALTH_FAIL_LIMIT="${HEALTH_FAIL_LIMIT:-3}"
TUNNEL_HEALTH_URL="${TUNNEL_HEALTH_URL:-}"
PID_DIR="/tmp/service-pids"

mkdir -p "${PID_DIR}"

if [ -z "${ARGO_TOKEN}" ] || [ "${ARGO_TOKEN}" = "${TOKEN_PLACEHOLDER}" ]; then
  echo "Error: ARGO_TOKEN is missing. 请在部署平台填写环境变量。"
  exit 1
fi

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

run_forever() {
  name="$1"
  shift
  pid_file="${PID_DIR}/${name}.pid"

  while true; do
    log "Starting ${name}..."
    "$@" &
    pid="$!"
    echo "${pid}" > "${pid_file}"
    log "${name} started, pid=${pid}"

    wait "${pid}"
    code="$?"
    rm -f "${pid_file}"

    log "${name} exited with code ${code}. Restarting in ${RESTART_DELAY}s..."
    sleep "${RESTART_DELAY}"
  done
}

stop_service() {
  name="$1"
  pid_file="${PID_DIR}/${name}.pid"

  if [ -f "${pid_file}" ]; then
    pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      log "Stopping ${name}, pid=${pid}. Watchdog will restart it."
      kill "${pid}" 2>/dev/null || true
      sleep 3
      kill -9 "${pid}" 2>/dev/null || true
    fi
  fi
}

cleanup() {
  log "Received stop signal. Cleaning up..."
  stop_service cloudflared
  stop_service caddy
  stop_service xray
  exit 0
}

keep_alive() {
  log "Starting Built-in Stable Keep-Alive Daemon..."
  while true; do
    # 1. 内部活跃：唤醒本地 Caddy 进程，防止系统判定进程休眠
    curl -s http://127.0.0.1:8080/ >/dev/null 2>&1 || true

    # 2. 外部活跃：向 Cloudflare 官方探针发送请求，维持网络 I/O 活跃
    curl -s https://1.1.1.1/cdn-cgi/trace >/dev/null 2>&1 || true

    # 每隔 10 分钟模拟一次呼吸
    sleep 600
  done
}

health_check() {
  caddy_fail=0
  tunnel_fail=0

  log "Starting health checker..."
  while true; do
    sleep "${HEALTH_INTERVAL}"

    # Caddy 本地健康检查：连续失败才重启，避免网络瞬断误杀
    if curl -fsS --max-time 8 http://127.0.0.1:8080/ >/dev/null 2>&1; then
      caddy_fail=0
    else
      caddy_fail=$((caddy_fail + 1))
      log "Caddy health check failed ${caddy_fail}/${HEALTH_FAIL_LIMIT}."
      if [ "${caddy_fail}" -ge "${HEALTH_FAIL_LIMIT}" ]; then
        log "Caddy seems unhealthy. Restarting Caddy..."
        stop_service caddy
        caddy_fail=0
      fi
    fi

    # 可选：填写 TUNNEL_HEALTH_URL=https://你的域名 后，可检测公网隧道是否可访问
    if [ -n "${TUNNEL_HEALTH_URL}" ]; then
      if curl -fsS --max-time 12 "${TUNNEL_HEALTH_URL}" >/dev/null 2>&1; then
        tunnel_fail=0
      else
        tunnel_fail=$((tunnel_fail + 1))
        log "Tunnel health check failed ${tunnel_fail}/${HEALTH_FAIL_LIMIT}."
        if [ "${tunnel_fail}" -ge "${HEALTH_FAIL_LIMIT}" ]; then
          log "Tunnel seems unhealthy. Restarting cloudflared..."
          stop_service cloudflared
          tunnel_fail=0
        fi
      fi
    fi
  done
}

trap cleanup INT TERM

log "Starting proxy services with watchdog..."

keep_alive &
health_check &

# Xray 前台运行，退出后自动拉起
run_forever xray /usr/bin/xray/xray run -c /etc/xray/config.json &

# Caddy 必须用 run，不要用 start；run 会以前台运行，方便 watchdog 感知退出
run_forever caddy caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &

# Cloudflare Tunnel 前台运行，退出后自动拉起
run_forever cloudflared /usr/bin/cloudflared tunnel --no-autoupdate run --token "${ARGO_TOKEN}" &

wait
