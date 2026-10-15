#!/bin/sh
# ---------------------------------------------------------------------------
# 网络看门狗：检测断网 → 渐进式自动恢复
#
# 恢复顺序：
#   L0  端口体检自愈 —— 模组拔插后 USB 总线/串口会变，而 qmodem 的
#       path / at_port 是写死的，会指向不存在的设备。表现为 eth1 有 IP
#       却 0 收包。这一级直接调用 /root/fix-modem.sh 就地修正。
#   L1  重建接口
#   L2  重启拨号服务
#   L3  模块射频复位
#
# 设计要点：
#   - 多目标探测（任一可达即在线），避免单点误判
#   - 连续失败达阈值才动作，避免网络抖动误触发
#   - 恢复后冷却观察，避免反复折腾
#   - 只在检测到真实断网时才动作，平时零干预
# ---------------------------------------------------------------------------
TARGETS="223.5.5.5 114.114.114.114 119.29.29.29"
INTERVAL=60      # 检测间隔（秒）
FAIL_NEED=3      # 连续失败多少次判定断网
COOLDOWN=90      # 每次恢复动作后的观察等待（秒）
HEAL_GAP=600     # L0 自愈的最小间隔（秒），防止反复折腾
SMS_BEAT=/tmp/sms_fwd_beat
SMS_STALL=300    # 短信转发心跳超过 5 分钟视为卡死
LOG="/tmp/net_watchdog.log"

log() {
    echo "[$(date '+%m-%d %H:%M:%S')] $1" >> "$LOG"
    logger -t net_watchdog "$1"
}

# ---- 短信转发服务心跳检查 ----
# 独立于网络状态：sms_fwd 曾因 sms_tool_q 阻塞而静默卡死 2 天，
# procd 只在进程"退出"时才会拉起，卡死不退出所以必须靠心跳发现。
check_sms_fwd() {
    [ -f "$SMS_BEAT" ] || return 0
    # 用户主动停用的服务不要去拉起它
    [ -x /etc/init.d/sms_fwd ] && /etc/init.d/sms_fwd enabled 2>/dev/null || return 0
    local now last
    now=$(date +%s)
    last=$(tr -dc '0-9' < "$SMS_BEAT" 2>/dev/null)
    [ -n "$last" ] || return 0
    if [ $((now - last)) -gt "$SMS_STALL" ]; then
        log "短信转发心跳超时 $((now - last))s，重启 sms_fwd"
        rm -f "$SMS_BEAT"
        rmdir /var/lock/sms_serial 2>/dev/null
        /etc/init.d/sms_fwd restart >/dev/null 2>&1
    fi
    return 0
}

# ---- 自动探测 AT 口（USB 重新枚举后会变，不能写死）----
detect_at_port() {
    for p in /dev/ttyUSB1 /dev/ttyUSB3 /dev/ttyUSB4 /dev/ttyUSB0 /dev/ttyUSB2 /dev/ttyUSB5; do
        [ -e "$p" ] || continue
        tom_modem -u -d "$p" -o a -c "AT" -t 4 2>/dev/null | grep -q '^OK' && { echo "$p"; return 0; }
    done
    return 1
}

# ---- 自动探测承载 eth1 的拨号接口（段名会随模组位置变化，如 4_1_2 → 3_1_2）----
# 注意：ubus list network.interface 只返回对象类型名，取不到实例，必须从 uci 读
detect_iface() {
    local i d
    for i in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^.]*\)=interface$/\1/p'); do
        case "$i" in
            lan|loopback|*v6) continue ;;
        esac
        d=$(uci -q get network.$i.device)
        [ -n "$d" ] || d=$(uci -q get network.$i.ifname)
        [ "$d" = "eth1" ] && { echo "$i"; return 0; }
    done
    return 1
}

# ---- 模组实际所在的 USB 位置 ----
modem_slot() {
    local d
    for d in /sys/bus/usb/devices/*/; do
        [ -f "$d/idVendor" ] || continue
        [ "$(cat "$d/idVendor" 2>/dev/null)" = "0e8d" ] && { basename "$d"; return 0; }
    done
    return 1
}

# ---- 判断 qmodem 配置是否已与真实设备错配（0=错配，1=正常）----
modem_config_stale() {
    local slot sec path at s
    slot=$(modem_slot) || return 1          # 模组都不在，不算配置问题
    sec=""
    for s in $(uci show qmodem 2>/dev/null | sed -n 's/^qmodem\.\([^.]*\)=modem-device$/\1/p'); do
        [ "$(uci -q get qmodem.$s.enable_dial)" = "1" ] && { sec="$s"; break; }
    done
    [ -n "$sec" ] || return 0               # 没有任何段在拨号 -> 需要修
    path=$(uci -q get qmodem.$sec.path)
    at=$(uci -q get qmodem.$sec.at_port)
    [ "$path" = "/sys/bus/usb/devices/$slot/" ] || return 0
    [ -n "$at" ] && [ -e "$at" ] || return 0
    return 1
}

HEAL_LAST=0
heal_modem_config() {
    local now
    now=$(date +%s)
    if [ $((now - HEAL_LAST)) -lt "$HEAL_GAP" ]; then
        log "L0 端口自愈冷却中（${HEAL_GAP}s 内已执行过）"
        return 1
    fi
    HEAL_LAST=$now
    if [ ! -x /root/fix-modem.sh ]; then
        log "L0 跳过：/root/fix-modem.sh 不存在"
        return 1
    fi
    log "L0：检测到模组端口错配，执行自愈修复"
    /root/fix-modem.sh >> "$LOG" 2>&1
    return 0
}

# 任一目标可达即认为在线
check_net() {
    local t
    for t in $TARGETS; do
        ping -c 1 -W 3 "$t" >/dev/null 2>&1 && return 0
    done
    return 1
}

# 分级恢复
recover() {
    local iface
    case "$1" in
        1)
            iface=$(detect_iface) || iface="4_1_2"
            log "恢复L1：重建接口 $iface"
            ubus call network.interface.$iface down >/dev/null 2>&1
            sleep 3
            ubus call network.interface.$iface up >/dev/null 2>&1
            ;;
        2)
            log "恢复L2：重启拨号服务"
            /etc/init.d/qmodem_network restart >/dev/null 2>&1
            ;;
        3)
            local at
            at=$(detect_at_port) || at="/dev/ttyUSB1"
            log "恢复L3：模块射频复位（$at）"
            tom_modem -u -d "$at" -o a -c "AT+CFUN=1,1" -t 8 >/dev/null 2>&1
            ;;
    esac
}

fails=0
level=0
AT_PORT=$(detect_at_port)
log "网络看门狗启动（间隔 ${INTERVAL}s，阈值 ${FAIL_NEED} 次，AT口=${AT_PORT:-未探测到}）"

while true; do
    check_sms_fwd          # 独立于网络状态：防止转发服务静默卡死

    if check_net; then
        if [ "$fails" -ge "$FAIL_NEED" ]; then
            log "网络已恢复（恢复级别 L$level 生效）"
        fi
        fails=0
        level=0
        sleep "$INTERVAL"
        continue
    fi

    fails=$((fails + 1))
    log "探测失败 $fails/$FAIL_NEED"

    if [ "$fails" -ge "$FAIL_NEED" ]; then
        # ---- L0：先做端口体检（拔插模组后最常见的断网原因）----
        if modem_config_stale; then
            if heal_modem_config; then
                sleep "$COOLDOWN"
                if check_net; then
                    log "L0 自愈成功，无需升级"
                    fails=0
                    level=0
                    sleep "$INTERVAL"
                    continue
                fi
                log "L0 自愈未成功，继续升级处理"
            fi
        fi

        # ---- L1~L3 渐进恢复 ----
        level=$((level + 1))
        [ "$level" -gt 3 ] && level=3
        recover "$level"
        sleep "$COOLDOWN"
        if check_net; then
            log "恢复成功（L$level）"
            fails=0
            level=0
        else
            log "L$level 未恢复，下一轮升级处理"
        fi
    fi
    sleep "$INTERVAL"
done
