#!/bin/sh
# ---------------------------------------------------------------------------
# cpe_tunnel.sh —— CPE 侧 SSH 反向隧道（保活，支持多通道）
#
# 用途：CPE 在运营商 NAT 后没有公网 IP，由 CPE 主动连出到你的服务器，
#       把服务器上的本地端口反向映射回 CPE 的服务，实现异地访问。
#
# 默认两条通道：
#   18111 → CPE:80    (LuCI 后台)
#   18112 → CPE:18998 (短信 API)
#
# 配置：/etc/cpe_tunnel.conf
#   TUNNEL_SERVER=root@your.server.com     # 必填
#   TUNNEL_KEY=/root/.ssh/id_ed25519_tunnel
#   TUNNEL_FORWARDS="18111:127.0.0.1:80 18112:127.0.0.1:18998"
#
# 注意：远端命令必须是"永不退出"的循环。
#       早期版本用 `sleep 86400`，结果每天到点会话正常结束（退出码 0），
#       隧道必然断一次，导致远程管理每天有几十秒不可用。
# ---------------------------------------------------------------------------
CONF=/etc/cpe_tunnel.conf
[ -f "$CONF" ] && . "$CONF"

TUNNEL_SERVER="${TUNNEL_SERVER:-}"
TUNNEL_KEY="${TUNNEL_KEY:-/root/.ssh/id_ed25519_tunnel}"
TUNNEL_FORWARDS="${TUNNEL_FORWARDS:-18111:127.0.0.1:80 18112:127.0.0.1:18998}"
LOG="${TUNNEL_LOG:-/tmp/cpe_tunnel.log}"
LOG_MAX=65536          # 日志超过 64KB 就裁剪，避免无限增长
RETRY=10               # 断线重连间隔（秒）

if [ -z "$TUNNEL_SERVER" ]; then
    echo "错误：请在 $CONF 中设置 TUNNEL_SERVER=user@host"
    exit 1
fi

log() { echo "[$(date '+%m-%d %H:%M:%S')] $1" >> "$LOG"; logger -t cpe_tunnel "$1"; }

# 日志轮转：保留最近 200 行
rotate_log() {
    [ -f "$LOG" ] || return 0
    [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX" ] || return 0
    tail -200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
}

# 组装 -R 参数
set -- 
for f in $TUNNEL_FORWARDS; do
    set -- "$@" -R "$f"
done

log "隧道服务启动（服务器 $TUNNEL_SERVER，转发: $TUNNEL_FORWARDS）"

while true; do
    rotate_log
    # -y: 接受未知主机密钥；-K: keepalive 20 秒
    # 远端用死循环维持会话（不能再用 sleep N，否则到点必断）
    ssh -i "$TUNNEL_KEY" -y -K 20 "$@" "$TUNNEL_SERVER" \
        "while true; do sleep 3600; done" >> "$LOG" 2>&1
    RC=$?
    log "隧道断开（退出码 $RC），${RETRY} 秒后重连"
    sleep "$RETRY"
done
