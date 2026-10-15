#!/bin/sh
# ---------------------------------------------------------------------------
# fix-modem.sh —— 拔插模组后一键自愈
#
# 背景：FM350 通过 USB 接入，重新插拔/重启会让它换到别的 USB 总线，
#       导致两处配置失效：
#         1) qmodem 的 modem 段 path（如 3-1.2）与实际不符
#         2) qmodem 的 at_port（如 ttyUSB3）指向已不存在的串口
#       表现就是"有 IP 但上不了网"。
#
# 用法：直接运行  /root/fix-modem.sh
# ---------------------------------------------------------------------------
echo "=== 1. 定位模组实际 USB 位置 ==="
SLOT=""
for d in /sys/bus/usb/devices/*/; do
    [ -f "$d/idVendor" ] || continue
    if [ "$(cat "$d/idVendor" 2>/dev/null)" = "0e8d" ]; then
        SLOT=$(basename "$d")
        break
    fi
done
if [ -z "$SLOT" ]; then
    echo "  ❌ 未找到 FM350 模组（检查 USB 连接/供电）"
    exit 1
fi
echo "  模组位置: $SLOT"

echo
echo "=== 2. 探测可用 AT 串口 ==="
AT=""
for p in /dev/ttyUSB1 /dev/ttyUSB3 /dev/ttyUSB4 /dev/ttyUSB0 /dev/ttyUSB2 /dev/ttyUSB5; do
    [ -e "$p" ] || continue
    if tom_modem -d "$p" -o a -c "AT" -t 4 2>/dev/null | grep -q '^OK'; then
        AT="$p"
        echo "  可用: $p"
        break
    fi
done
if [ -z "$AT" ]; then
    echo "  ❌ 未找到可用 AT 串口"
    exit 1
fi

echo
echo "=== 3. 找 qmodem 中匹配该位置的段 ==="
SEC=""
for s in $(uci show qmodem 2>/dev/null | sed -n 's/^qmodem\.\([^.]*\)=modem-device$/\1/p'); do
    P=$(uci -q get qmodem.$s.path)
    echo "  检查 $s → $P"
    [ "$P" = "/sys/bus/usb/devices/$SLOT/" ] && { SEC="$s"; break; }
done

if [ -z "$SEC" ]; then
    echo "  ⚠️ 没有匹配的段。先重启 qmodem 让它重新扫描，再跑一次本脚本："
    echo "     /etc/init.d/qmodem_init restart; sleep 10; /root/fix-modem.sh"
    exit 1
fi
echo "  匹配段: $SEC"

echo
echo "=== 4. 修正配置 ==="
BK=/root/qmodem.bak.$(date +%Y%m%d-%H%M%S)
cp /etc/config/qmodem "$BK" && echo "  备份 -> $BK"

# 清理指向不存在的 USB 位置的垃圾段
for s in $(uci show qmodem 2>/dev/null | sed -n 's/^qmodem\.\([^.]*\)=modem-device$/\1/p'); do
    [ "$s" = "$SEC" ] && continue
    P=$(uci -q get qmodem.$s.path)
    D=${P#/sys/bus/usb/devices/}
    D=${D%/}
    if [ ! -d "/sys/bus/usb/devices/$D" ]; then
        uci delete "qmodem.$s" 2>/dev/null && echo "  删除失效段: $s ($P)"
    fi
done

uci set qmodem.$SEC.at_port="$AT"
uci delete qmodem.$SEC.valid_at_ports 2>/dev/null
uci add_list qmodem.$SEC.valid_at_ports="$AT"
uci delete qmodem.$SEC.ports 2>/dev/null
uci add_list qmodem.$SEC.ports="$AT"
uci set qmodem.$SEC.enable_dial='1'
uci set qmodem.$SEC.state='enabled'
uci set qmodem.main.modem_count='1'
uci commit qmodem
echo "  $SEC: at_port=$AT, 拨号已启用"

echo
echo "=== 5. 重启服务并等待拨号 ==="
/etc/init.d/ubus-at-daemon restart 2>/dev/null
sleep 4
/etc/init.d/qmodem_init restart 2>/dev/null
sleep 4
/etc/init.d/qmodem_network restart 2>/dev/null

for i in $(seq 1 12); do
    sleep 5
    if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then
        echo "  ✅ 第 $((i*5)) 秒：网络已通"
        break
    fi
    [ "$i" = "12" ] && echo "  ⚠️ 90 秒仍未通，可尝试重启设备"
done

echo
echo "=== 6. 结果 ==="
ip -4 addr show eth1 2>/dev/null | grep inet | sed 's/^/  /'
ping -c 2 -W 3 223.5.5.5 2>&1 | tail -1 | sed 's/^/  /'
