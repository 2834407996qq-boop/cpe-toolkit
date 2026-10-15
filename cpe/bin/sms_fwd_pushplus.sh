#!/bin/sh
# ---------------------------------------------------------------------------
# PushPlus 短信转发服务（含关键词过滤 + 转发后自动删除）
# 用法:
#   sms_fwd_pushplus.sh test    # 发一条测试推送
#   sms_fwd_pushplus.sh once    # 手动轮询一次（调试）
#   sms_fwd_pushplus.sh start   # 守护模式（由 procd 服务调用）
# 配置: /etc/pushplus.conf
#   TOKEN=你的token
#   FILTER_MODE=off|whitelist|blacklist   # whitelist=只推含关键词; blacklist=过滤含关键词
#   FILTER_KEYWORDS=关键词1,关键词2       # 逗号分隔
#   AUTO_DELETE=1                         # 1=转发后自动删除短信(防卡满)
# ---------------------------------------------------------------------------
CONF=/etc/pushplus.conf
SEEN=/tmp/sms_fwd_seen
BEAT=/tmp/sms_fwd_beat   # 心跳：主循环每轮更新时间戳，看门狗据此发现"卡死"
# 短信口会被 USB 重新枚举改变，默认 ttyUSB3，启动后会自动探测可用的端口
PORT="${SMS_PORT:-/dev/ttyUSB3}"
POLL=20

[ -f "$CONF" ] || { echo "缺少配置文件 $CONF"; exit 1; }
. "$CONF"
[ -n "$TOKEN" ] || { echo "TOKEN 未设置，请编辑 $CONF"; exit 1; }

# ---- 推送到 PushPlus ----
send() {
    local title="$1" content="$2"
    local payload resp
    payload=$(jq -n --arg t "$TOKEN" --arg ti "$title" --arg c "$content" \
        '{token:$t, title:$ti, content:$c, template:"txt"}')
    resp=$(curl -s -m 25 -X POST "http://www.pushplus.plus/send" \
        -H "Content-Type: application/json" -d "$payload" 2>&1)
    echo "$resp"
}

# ---- 带限流退避的推送：成功返回 0，失败返回 1 ----
push_with_retry() {
    local key="$1" sender="$2" content="$3"
    local attempt=1 max="${PUSH_RETRY:-3}" resp
    while [ "$attempt" -le "$max" ]; do
        resp=$(send "短信 $sender" "$content")
        if echo "$resp" | grep -q '"code":200'; then
            logger -t sms_fwd "push OK key=$key sender=$sender attempt=$attempt"
            echo "[$(date '+%m-%d %H:%M:%S')] 推送成功 key=$key sender=$sender"
            return 0
        fi
        # 仅对服务端限流做退避重试；其他错误立即返回，交由下一轮处理
        if echo "$resp" | grep -q '频率'; then
            logger -t sms_fwd "push 限流 key=$key 第${attempt}次，退避 ${PUSH_BACKOFF:-6}s"
            sleep "${PUSH_BACKOFF:-6}"
            attempt=$((attempt + 1))
            continue
        fi
        logger -t sms_fwd "push 失败 key=$key resp=$(echo "$resp" | head -c 120)"
        echo "[$(date '+%m-%d %H:%M:%S')] 推送失败(非限流) key=$key"
        return 1
    done
    logger -t sms_fwd "push 重试耗尽 key=$key（保留待下一轮）"
    return 1
}

# ---- 推送到自建短信网关（SERVER_URL），成功返回 0 ----
push_server() {
    local sender="$1" content="$2" ts="$3" parts="$4" key="$5"
    [ -z "$SERVER_URL" ] && return 0   # 未配置则视为成功（不阻塞主流程）
    curl -s -m 20 -X POST "$SERVER_URL" -H 'Content-Type: application/json' \
        -d "$(jq -n --arg t "$SERVER_TOKEN" --arg s "$sender" --arg c "$content" \
              --arg ts "$ts" --arg k "$key" --argjson p "${parts:-1}" \
              '{token:$t,sender:$s,content:$c,ts:$ts,md5:$k,parts:$p}')" 2>/dev/null \
        | grep -q '"ok":1'
}

# ---- 关键词过滤：返回 0=推送, 1=过滤 ----
match_filter() {
    local content="$1" kw
    case "${FILTER_MODE:-off}" in
        off) return 0 ;;
        whitelist)
            [ -z "$FILTER_KEYWORDS" ] && return 0
            for kw in $(echo "$FILTER_KEYWORDS" | tr ',' ' '); do
                echo "$content" | grep -qF "$kw" && return 0
            done
            return 1
            ;;
        blacklist)
            [ -z "$FILTER_KEYWORDS" ] && return 0
            for kw in $(echo "$FILTER_KEYWORDS" | tr ',' ' '); do
                echo "$content" | grep -qF "$kw" && return 1
            done
            return 0
            ;;
        *) return 0 ;;
    esac
}

# ---- 串口互斥锁 ----------------------------------------------------------
# /dev/ttyUSB3 是独占资源。本脚本、sms_api.py、ubus-at-daemon 都会访问它，
# 并发读写会让 AT 响应错乱（表现为 "sms not sent, command error"）。
# 用 mkdir 原子操作做锁，与 sms_api.py 使用同一个锁目录。
SMS_LOCK=/var/lock/sms_serial

lock_try() {   # 非阻塞获取；成功返回 0
    local i=0
    while [ $i -lt 3 ]; do
        mkdir "$SMS_LOCK" 2>/dev/null && return 0
        if [ -d "$SMS_LOCK" ]; then
            local age=$(( $(date +%s) - $(stat -c %Y "$SMS_LOCK" 2>/dev/null || echo 0) ))
            [ "$age" -gt 90 ] && rmdir "$SMS_LOCK" 2>/dev/null
        fi
        i=$((i+1)); sleep 1
    done
    return 1
}
lock_done() { rmdir "$SMS_LOCK" 2>/dev/null; }

# ---- 限时删除短信 ----------------------------------------------------------
# sms_tool_q 在串口异常时会永久阻塞；本设备没有 timeout 命令，
# 只能用"后台执行 + 超时 kill"兜底。否则会卡死整个轮询循环（曾静默停摆 2 天）。
delete_msgs() {
    lock_try || { logger -t sms_fwd "删除跳锁，短信留到下一轮"; return 1; }
    ( for idx in $1; do
          sms_tool_q -d "$PORT" delete "$idx" >/dev/null 2>&1
      done ) &
    _dp=$!
    sleep 10
    kill -9 "$_dp" 2>/dev/null
    wait "$_dp" 2>/dev/null
    lock_done
}

# ---- SEEN 裁剪 -------------------------------------------------------------
# SEEN 只是去重表，保留最近若干条足够；不裁剪会随短信量无限增长。
trim_seen() {
    [ -f "$SEEN" ] || return 0
    [ "$(wc -l < "$SEEN" 2>/dev/null || echo 0)" -gt 2000 ] || return 0
    tail -1000 "$SEEN" > "$SEEN.tmp" 2>/dev/null && mv "$SEEN.tmp" "$SEEN"
}

# ---- 限时读取短信（设备无 timeout 命令，用后台+kill 实现；坏端口不会永久卡住）----
try_recv() {
    lock_try || return 2          # 2 = 串口忙（必须与"端口故障"区分开）
    : > /tmp/sms_recv.tmp
    ( sms_tool_q -d "$1" -j recv > /tmp/sms_recv.tmp 2>/dev/null ) &
    local pid=$! i=0
    # 完成即释放锁（不能固定睡 12 秒，否则会把网页发短信的请求饿死）
    while [ $i -lt 12 ]; do
        if [ -s /tmp/sms_recv.tmp ] && [ "$(tail -c 1 /tmp/sms_recv.tmp 2>/dev/null)" = "}" ]; then
            break
        fi
        sleep 1
        i=$((i+1))
    done
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    lock_done
    cat /tmp/sms_recv.tmp 2>/dev/null
}

# ---- 自动探测可用的短信口（USB 重新枚举后端口会变）----
# 只探测最可能的 3 个端口：每个探测都要持锁，端口列太长会长时间独占串口
detect_port() {
    local p
    for p in /dev/ttyUSB3 /dev/ttyUSB1 /dev/ttyUSB0; do
        [ -e "$p" ] || continue
        if try_recv "$p" | jq -e '.msg' >/dev/null 2>&1; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# ---- 单次轮询 ----
poll_once() {
    local json line ref indexes sender content resp push_ok idx rc
    json=$(try_recv "$PORT"); rc=$?

    # 串口被占用 ≠ 端口故障：直接跳过本轮，绝不能触发端口探测
    # （detect_port 会逐个端口抢锁，形成级联饿死，曾把网页发短信拖成 0 成功率）
    if [ "$rc" = "2" ]; then
        logger -t sms_fwd "串口忙，跳过本轮"
        return
    fi

    # 当前端口失效则自动切换（这是 15 天零推送的根因：端口变了服务不知道）
    if ! echo "$json" | jq -e '.msg' >/dev/null 2>&1; then
        local np
        np=$(detect_port)
        if [ -n "$np" ]; then
            logger -t sms_fwd "短信口自动切换: $PORT -> $np"
            echo "[$(date '+%m-%d %H:%M:%S')] 短信口切换 $PORT -> $np"
            PORT="$np"
            json=$(try_recv "$PORT")
        fi
    fi
    [ -z "$json" ] && return

    # 分组键 = reference + timestamp（长短信分段同 reference 同秒到达；
    # reference 循环复用必须配合 timestamp 区分无关短信）。
    # 去重键 = content 的 md5：index/reference 删除后都会复用，只有内容唯一。
    echo "$json" | jq -c '
        .msg | group_by([.reference, (.timestamp // "")]) | map(
            {
                indexes: ([.[].index]),
                sender:  (.[0].sender // "未知号码"),
                ts:      (.[0].timestamp // ""),
                content: (sort_by(.part) | map(.content // "") | join(""))
            }
        ) | .[]
    ' 2>/dev/null | while read -r line; do
        [ -z "$line" ] && continue
        indexes=$(echo "$line" | jq -r '.indexes[]' 2>/dev/null | tr '\n' ' ')
        sender=$(echo "$line"  | jq -r '.sender'  2>/dev/null)
        ts=$(echo "$line"      | jq -r '.ts'      2>/dev/null)
        content=$(echo "$line" | jq -r '.content' 2>/dev/null)
        [ -z "$content" ] && continue

        # 去重键：内容 md5
        key=$(echo "$content" | md5sum | cut -d' ' -f1)
        if grep -qx "$key" "$SEEN" 2>/dev/null; then
            # 已处理过：仍要清掉卡里的副本，否则旧短信会慢慢占满 SIM 存储
            [ "${AUTO_DELETE:-0}" = "1" ] && delete_msgs "$indexes"
            continue
        fi

        # 推送到自建服务（网页留存，全部短信都存）；失败则保留重试
        parts=$(echo "$indexes" | wc -w)
        if push_server "$sender" "$content" "$ts" "$parts" "$key"; then sv=1; else sv=0; fi

        # 先推送，成功（或被规则过滤）后才落库 SEEN；
        # 失败则保留短信交给下一轮重试，避免静默丢失。
        if match_filter "$content"; then
            push_with_retry "$key" "$sender" "$content" && pp=1 || pp=0
        else
            pp=1
            logger -t sms_fwd "filter key=$key sender=$sender"
            echo "[$(date '+%m-%d %H:%M:%S')] 过滤 key=$key sender=$sender"
        fi
        # 两个目标都成功才算完成；任一失败则保留短信下轮重试
        [ "$pp" = "1" ] && [ "$sv" = "1" ] && push_ok=1 || push_ok=0
        [ "$push_ok" = "1" ] || continue

        echo "$key" >> "$SEEN"
        [ "${AUTO_DELETE:-0}" = "1" ] && delete_msgs "$indexes"

        # 推送节流，避免连续推送触发服务端频率限制
        [ "${PUSH_GAP:-0}" -gt 0 ] && sleep "${PUSH_GAP:-2}"
    done
}

case "${1:-}" in
    test)
        resp=$(send "短信转发测试" "这是一条来自 CPE 的测试推送。收到说明 PushPlus 链路正常。")
        echo "响应: $resp"
        ;;
    once)
        poll_once
        ;;
    start)
        # 启动时自动探测可用短信口（USB 重新枚举后端口会变）
        NP=$(detect_port)
        if [ -n "$NP" ]; then
            PORT="$NP"
            echo "[$(date '+%m-%d %H:%M:%S')] 自动探测到短信口: $PORT"
        else
            echo "[$(date '+%m-%d %H:%M:%S')] 警告: 未探测到可用短信口，仍按 $PORT 尝试"
        fi

        if [ ! -f "$SEEN" ]; then
            # 首次启动：用与轮询一致的合并逻辑，把当前所有短信内容的 md5 标记为已读
            try_recv "$PORT" | jq -c '
                .msg | group_by([.reference, (.timestamp // "")]) | map(
                    (sort_by(.part) | map(.content // "") | join(""))
                ) | .[]
            ' 2>/dev/null | while read -r c; do
                echo "$c" | md5sum | cut -d' ' -f1
            done | sort -u > "$SEEN"
            echo "[$(date '+%m-%d %H:%M:%S')] 首次启动，标记 $(wc -l < "$SEEN") 条历史短信为已读"
        fi
        echo "PushPlus 短信转发服务启动 (端口=$PORT, 轮询=${POLL}s, 过滤=${FILTER_MODE:-off}, 自动删除=${AUTO_DELETE:-0})"
        date +%s > "$BEAT"
        while true; do
            poll_once
            trim_seen
            date +%s > "$BEAT"
            sleep "$POLL"
        done
        ;;
    *)
        echo "用法: $0 {start|test|once}"
        echo "配置文件: $CONF"
        exit 1
        ;;
esac
