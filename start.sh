#!/usr/bin/env bash
set -Eeuo pipefail

TOKEN_PLACEHOLDER="PASTE_YOUR_CLOUDFLARE_TUNNEL_TOKEN_HERE"
ARGO_TOKEN="${ARGO_TOKEN:-}"
RESTART_DELAY="${RESTART_DELAY:-5}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-60}"
HEALTH_FAIL_LIMIT="${HEALTH_FAIL_LIMIT:-3}"
TUNNEL_HEALTH_URL="${TUNNEL_HEALTH_URL:-}"
TUNNEL_EDGE_PROTOCOL="${TUNNEL_EDGE_PROTOCOL:-}"
CADDY_HEALTH_URL="${CADDY_HEALTH_URL:-http://127.0.0.1:8080/healthz}"
PID_DIR="/tmp/service-pids"

mkdir -p "${PID_DIR}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

if [ -z "${ARGO_TOKEN}" ] || [ "${ARGO_TOKEN}" = "${TOKEN_PLACEHOLDER}" ]; then
  log "Error: ARGO_TOKEN is missing. 请在部署平台填写环境变量。"
  exit 1
fi

run_forever() {
  local name="$1"
  shift
  local pid_file="${PID_DIR}/${name}.pid"

  while true; do
    log "Starting ${name}..."
    "$@" &
    local pid="$!"
    echo "${pid}" > "${pid_file}"
    log "${name} started, pid=${pid}"

    wait "${pid}" || true
    local code="$?"
    rm -f "${pid_file}"
    log "${name} exited with code ${code}. Restarting in ${RESTART_DELAY}s..."
    sleep "${RESTART_DELAY}"
  done
}

stop_service() {
  local name="$1"
  local pid_file="${PID_DIR}/${name}.pid"

  if [ -f "${pid_file}" ]; then
    local pid
    pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      log "Stopping ${name}, pid=${pid}. Watchdog will restart it if main script continues."
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
  log "Starting keep-alive daemon..."
  while true; do
    curl -fsS --max-time 8 "${CADDY_HEALTH_URL}" >/dev/null 2>&1 || true
    curl -fsS --max-time 8 https://1.1.1.1/cdn-cgi/trace >/dev/null 2>&1 || true
    sleep 600
  done
}

health_check() {
  local caddy_fail=0
  local tunnel_fail=0

  log "Starting health checker..."
  while true; do
    sleep "${HEALTH_INTERVAL}"

    if curl -fsS --max-time 8 "${CADDY_HEALTH_URL}" >/dev/null 2>&1; then
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

log "Validating Xray config..."
/usr/bin/xray/xray run -test -c /etc/xray/config.json

log "Validating Caddy config..."
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

log "Starting proxy services with watchdog..."
keep_alive &
health_check &

run_forever xray /usr/bin/xray/xray run -c /etc/xray/config.json &
sleep 2
run_forever caddy caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
sleep 2
run_forever cloudflared /usr/bin/cloudflared tunnel --no-autoupdate  run --token "${ARGO_TOKEN}" &

wait
