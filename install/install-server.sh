#!/bin/bash
# ============================================================
# 服务器端一键安装（在你的公网服务器上以 root 运行）
#
#   bash install-server.sh
#
# 安装内容：
#   /opt/sms/sms_server.py    短信网关服务
#   /opt/sms/ui.html          Web 界面
#   /opt/sms/config.json      配置（自动生成随机令牌）
#   /etc/systemd/system/sms-server.service
#
# 需要：python3（只用标准库，无需 pip）
# ============================================================
set -e
SRC=$(cd "$(dirname "$0")/.." && pwd)

[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "缺少 python3"; exit 1; }

echo "==> 1. 建立目录 /opt/sms"
mkdir -p /opt/sms/db
echo "    ✅"

echo
echo "==> 2. 安装程序文件"
cp "$SRC/server/sms_server.py" /opt/sms/
cp "$SRC/server/sms_ui.html"   /opt/sms/
chmod 755 /opt/sms/sms_server.py
echo "    ✅ sms_server.py / ui.html"

echo
echo "==> 3. 生成配置（已存在则保留）"
if [ -f /opt/sms/config.json ]; then
    echo "    /opt/sms/config.json 已存在，跳过"
    TOKEN=$(python3 -c "import json;print(json.load(open('/opt/sms/config.json')).get('token',''))" 2>/dev/null)
else
    TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
    cat > /opt/sms/config.json <<EOF
{
  "token": "$TOKEN",
  "db": "/opt/sms/db/sms.db",
  "cpe": "http://127.0.0.1:18112",
  "port": 18999,
  "ui": "/opt/sms/ui.html"
}
EOF
    chmod 600 /opt/sms/config.json
    echo "    ✅ 已生成，令牌为随机值"
fi

echo
echo "==> 4. 安装 systemd 服务"
cp "$SRC/server/systemd/sms-server.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable sms-server >/dev/null 2>&1 || true
systemctl restart sms-server
sleep 2
echo "    服务状态: $(systemctl is-active sms-server)"
curl -s -o /dev/null -w "    本地自测 http://127.0.0.1:18999/health → %{http_code}\n" \
    -m 5 http://127.0.0.1:18999/health || true

echo
echo "==> 5. 安装 nginx 反代片段"
if [ -d /etc/nginx/snippets ]; then
    cp "$SRC/server/nginx/cpe-proxy.conf" /etc/nginx/snippets/ 2>/dev/null || true
    cp "$SRC/server/nginx/sms-proxy.conf" /etc/nginx/snippets/ 2>/dev/null || true
    echo "    ✅ 已复制到 /etc/nginx/snippets/"
else
    echo "    ⚠️ 未找到 /etc/nginx/snippets，请手动复制 server/nginx/*.conf"
fi

echo
echo "==> 6. 创建访问密码（Basic Auth）"
if [ ! -f /etc/nginx/.htpasswd_cpe ]; then
    if command -v openssl >/dev/null 2>&1; then
        PASS=$(head -c 9 /dev/urandom | base64 | tr -d '/+=' | head -c 12)
        echo "admin:$(openssl passwd -apr1 "$PASS")" > /etc/nginx/.htpasswd_cpe
        chmod 640 /etc/nginx/.htpasswd_cpe
        echo "    ✅ 已生成"
        echo "       用户名: admin"
        echo "       密码:   $PASS"
        echo "       （请立即保存，此密码只显示这一次）"
    else
        echo "    ⚠️ 缺少 openssl，请手动创建 /etc/nginx/.htpasswd_cpe"
    fi
else
    echo "    /etc/nginx/.htpasswd_cpe 已存在，跳过"
fi

echo
echo "============================================================"
echo "服务器端安装完成。"
echo
echo "还需要手动做两件事："
echo
echo "  A) 在 nginx 站点配置的 server{} 里，于 location / 之前加入："
echo "       include /etc/nginx/snippets/cpe-proxy.conf;"
echo "       include /etc/nginx/snippets/sms-proxy.conf;"
echo "     然后：nginx -t && systemctl reload nginx"
echo
echo "  B) 在 CPE 的 /etc/pushplus.conf 里填入："
echo "       SERVER_URL=https://你的域名/api/sms"
echo "       SERVER_TOKEN=$TOKEN"
echo "============================================================"
