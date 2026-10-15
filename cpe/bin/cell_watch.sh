#!/bin/sh
# ---------------------------------------------------------------------------
# 驻留小区监控：长期记录设备驻留过的小区，用于判断哪些属于校园流量覆盖
#   /root/cell_known.txt  - 驻留过的小区汇总（PCI TAC CellID 最佳RSRP 首次时间）
#   /root/cell_events.log - 驻留切换事件
# 判断依据：TAC 相同 => 大概率同属一个跟踪区/覆盖区域
# 注意：USB 重新枚举会改变 AT 串口名，因此必须自动探测，不能写死。
# ---------------------------------------------------------------------------
KNOWN=/root/cell_known.txt
EVENTS=/root/cell_events.log
LAST=""

detect_at() {
    for p in /dev/ttyUSB1 /dev/ttyUSB3 /dev/ttyUSB4 /dev/ttyUSB0 /dev/ttyUSB2 /dev/ttyUSB5; do
        [ -e "$p" ] || continue
        if tom_modem -u -d "$p" -o a -c "AT" -t 4 2>/dev/null | grep -q '^OK'; then
            echo "$p"; return 0
        fi
    done
    return 1
}

P=$(detect_at)
[ -n "$P" ] || P=/dev/ttyUSB1
echo "[$(date '+%m-%d %H:%M:%S')] cell_watch 启动（端口=$P）" >> "$EVENTS"

[ -f "$KNOWN" ] || echo "# PCI TAC CellID 最佳RSRP 首次记录时间" > "$KNOWN"

while true; do
    TS=$(date '+%m-%d %H:%M:%S')

    # 端口消失则重新探测（拔插模组后会发生）
    if [ ! -e "$P" ]; then
        NP=$(detect_at)
        if [ -n "$NP" ]; then
            P="$NP"
            echo "$TS 端口变更 -> $P" >> "$EVENTS"
        else
            sleep 20; continue
        fi
    fi

    CA=$(tom_modem -u -d "$P" -o a -c "AT+GTCAINFO?" -t 5 2>/dev/null | tr -d '\r' | grep -o 'PCC:.*')
    CC=$(tom_modem -u -d "$P" -o a -c "AT+GTCCINFO?" -t 5 2>/dev/null | tr -d '\r' | grep '^1,')

    PCI=$(echo "$CA"  | cut -d, -f2 | tr -dc '0-9')
    RSRP=$(echo "$CA" | awk -F, '{print $NF}' | tr -dc '0-9-')
    TAC=$(echo "$CC"  | cut -d, -f5 | tr -dc '0-9')
    CID=$(echo "$CC"  | cut -d, -f6 | tr -dc '0-9')

    if [ -n "$PCI" ]; then
        if ! grep -q "^$PCI " "$KNOWN" 2>/dev/null; then
            echo "$PCI $TAC $CID $RSRP $TS" >> "$KNOWN"
        else
            OLD=$(grep "^$PCI " "$KNOWN" | awk '{print $4}')
            if [ -n "$RSRP" ] && [ -n "$OLD" ] && [ "$RSRP" -gt "$OLD" ] 2>/dev/null; then
                sed -i "s/^$PCI .*/$PCI $TAC $CID $RSRP $TS/" "$KNOWN"
            fi
        fi

        if [ "$PCI" != "$LAST" ]; then
            echo "$TS 切换 -> PCI=$PCI RSRP=${RSRP}dBm TAC=$TAC CellID=$CID" >> "$EVENTS"
            LAST="$PCI"
        fi
    fi

    # 事件日志裁剪：/root 落在 overlayfs(flash) 上，不能无限增长
    if [ -f "$EVENTS" ] && [ "$(wc -l < "$EVENTS" 2>/dev/null || echo 0)" -gt 3000 ]; then
        tail -1500 "$EVENTS" > "$EVENTS.tmp" 2>/dev/null && mv "$EVENTS.tmp" "$EVENTS"
    fi

    sleep 20
done
