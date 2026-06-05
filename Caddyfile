:8080 {
    # Cloudflare Tunnel 的 Public Hostname 服务请填：http://localhost:8080
    # 不要在本地 Caddy 开 tls internal，否则 cloudflared/http 健康检查会被重置。

    @health path /healthz /health /ping
    respond @health "ok" 200

    handle /ss* {
        reverse_proxy 127.0.0.1:10001
    }

    handle /vless* {
        reverse_proxy 127.0.0.1:10002
    }

    handle /vmess* {
        reverse_proxy 127.0.0.1:10003
    }

    # XHTTP 是流式请求，关闭响应缓冲，减少 reset/EOF/卡住。
    handle /xhttp-vless* {
        reverse_proxy 127.0.0.1:10005 {
            flush_interval -1
        }
    }

    # gRPC 需要 h2c 明文 HTTP/2 转发。
    handle /grpc-vless* {
        reverse_proxy h2c://127.0.0.1:10006
    }

    handle {
        respond "Hello World" 200
    }
}
