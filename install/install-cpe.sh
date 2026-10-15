#!/bin/sh
# ============================================================
# CPE 端一键安装（在 CPE 上以 root 运行）
#
#   sh install-cpe.sh
#
# 安装内容：
#   /usr/bin/     sms_fwd_pushplus.sh  sms_api.py  cell_watch.sh
#                 net_watchdog.sh      cpe_tunnel.sh  fix-modem.sh
#   /etc/init.d/  sms_fwd  sms_api  cell_watch  net_watchdog  cpe_tunnel
#   /etc/*.conf   各服务的配置模板（已存在则不动）
#
# 幂等：可重复运行，不会覆盖你已有的配置。
# ============================================================
set -e
SRC=$(cd "$(dirname "$0")/.." && pwd)

[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }
[ -f /etc/openwrt_release ] || echo "警告：这似乎不是 OpenWrt 系统，继续可能有风险"
command -v python3 >/dev/null 2>&1 || echo "警告：未找到 python3，短信 API 将无法运行"

echo "==> 1. 安装可执行脚本到 /usr/bin/"
for f in sms_fwd_pushplus.sh sms_api.py cell_watch.sh net_watchdog.sh cpe_tunnel.sh fix-modem.sh; do
    if [ -f "$SRC/cpe/bin/$f" ]; then
        cp "$SRC/cpe/bin/$f" /usr/bin/
        chmod 755 "/usr/bin/$f"
        echo "    ✅ $f"
    else
        echo "    ⚠️ 跳过缺失文件 $f"
    fi
done

echo
echo "==> 2. 安装 procd 服务到 /etc/init.d/"
for s in sms_fwd sms_api cell_watch net_watchdog cpe_tunnel; do
    if [ -f "$SRC/cpe/init.d/$s" ]; then
        cp "$SRC/cpe/init.d/$s" /etc/init.d/
        chmod 755 "/etc/init.d/$s"
        echo "    ✅ $s"
    fi
done

echo
echo "==> 3. 生成配置文件（已存在则保留）"
[ -f /etc/pushplus.conf ] || {
    cp "$SRC/conf/pushplus.conf.example" /etc/pushplus.conf
    chmod 600 /etc/pushplus.conf
    echo "    ✅ /etc/pushplus.conf（请编辑填入 TOKEN / SERVER_URL / SERVER_TOKEN）"
}
[ -f /etc/cpe_tunnel.conf ] || {
    cp "$SRC/conf/cpe_tunnel.conf.example" /etc/cpe_tunnel.conf
    chmod 600 /etc/cpe_tunnel.conf
    echo "    ✅ /etc/cpe_tunnel.conf（请编辑填入 TUNNEL_SERVER）"
}

echo
echo "==> 4. 生成隧道专用密钥"
if [ -f /root/.ssh/id_ed25519_tunnel ]; then
    echo "    已存在，跳过"
else
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    if command -v ssh-keygen >/dev/null 2>&1; then
        ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_tunnel -N "" -C "cpe-tunnel" >/dev/null
        echo "    ✅ 已生成（ssh-keygen）"
    elif command -v dropbearkey >/dev/null 2>&1; then
        dropbearkey -t ed25519 -f /root/.ssh/id_ed25519_tunnel >/dev/null
        echo "    ✅ 已生成（dropbearkey）"
    else
        echo "    ❌ 没有可用的密钥生成工具"
        exit 1
    fi
fi

echo
echo "==> 5. 公钥内容（请加到服务器的 /root/.ssh/authorized_keys）"
echo "------------------------------------------------------------"
if [ -f /root/.ssh/id_ed25519_tunnel.pub ]; then
    cat /root/.ssh/id_ed25519_tunnel.pub
else
    dropbearkey -y -f /root/.ssh/id_ed25519_tunnel 2>/dev/null | grep -E '^ssh-|^ecdsa'
fi
echo "------------------------------------------------------------"

echo
echo "==> 6. 启用开机自启"
for s in sms_fwd sms_api cell_watch net_watchdog cpe_tunnel; do
    [ -f "/etc/init.d/$s" ] && /etc/init.d/$s enable 2>/dev/null && echo "    ✅ $s"
done

echo
echo "============================================================"
echo "安装完成。接下来："
echo "  1) 编辑 /etc/pushplus.conf   填入 PushPlus TOKEN（可选）"
echo "     以及自建网关 SERVER_URL / SERVER_TOKEN（可选）"
echo "  2) 编辑 /etc/cpe_tunnel.conf 填入 TUNNEL_SERVER=user@host"
echo "  3) 把上面的公钥加到服务器 ~/.ssh/authorized_keys"
echo "  4) 逐个启动："
echo "       /etc/init.d/cpe_tunnel start"
echo "       /etc/init.d/sms_fwd start"
echo "       /etc/init.d/sms_api start"
echo "       /etc/init.d/cell_watch start"
echo "       /etc/init.d/net_watchdog start"
echo
echo "  排障：/root/fix-modem.sh   ← 拔插模组后若上不了网，跑这个"
echo "============================================================"
