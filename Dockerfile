FROM cloudflare/cloudflared:latest AS tunnel-builder
FROM alpine:latest

ARG ARGO_TOKEN=""
ENV ARGO_TOKEN="${ARGO_TOKEN}"
ENV XRAY_VERSION="26.5.9"
ENV TUNNEL_EDGE_PROTOCOL="http2"

RUN apk add --no-cache \
      bash \
      ca-certificates \
      caddy \
      curl \
      dos2unix \
      libc6-compat \
      unzip \
    && update-ca-certificates

COPY --from=tunnel-builder /usr/local/bin/cloudflared /usr/bin/cloudflared

RUN set -eux; \
    ARCH="$(uname -m)"; \
    case "${ARCH}" in \
      x86_64) XRAY_ARCH="64" ;; \
      aarch64) XRAY_ARCH="arm64-v8a" ;; \
      *) XRAY_ARCH="64" ;; \
    esac; \
    curl -fsSL -H "Cache-Control: no-cache" \
      -o /tmp/xray.zip \
      "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"; \
    mkdir -p /usr/bin/xray; \
    unzip -q /tmp/xray.zip -d /usr/bin/xray/; \
    rm -f /tmp/xray.zip; \
    chmod +x /usr/bin/xray/xray; \
    /usr/bin/xray/xray version | head -n 1; \
    /usr/bin/cloudflared --version

COPY config.json /etc/xray/config.json
COPY Caddyfile /etc/caddy/Caddyfile
COPY start.sh /start.sh

RUN dos2unix /start.sh /etc/caddy/Caddyfile /etc/xray/config.json \
    && chmod +x /start.sh \
    && /usr/bin/xray/xray run -test -c /etc/xray/config.json \
    && caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

CMD ["/start.sh"]
