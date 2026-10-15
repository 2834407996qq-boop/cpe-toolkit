# 运维手册

日常检查、维护与回滚命令速查。

---

## 一、日常健康检查

### CPE 端

```sh
# 一眼看全：服务状态 + 网络 + 心跳
for s in sms_fwd sms_api cell_watch net_watchdog cpe_tunnel; do
    printf '%-16s %s\n' "$s" "$(ps w | grep -c "[${s:0:1}]${s:1}")"
done
ping -c 2 -W 3 223.5.5.5
echo "心跳距今 $(( $(date +%s) - $(cat /tmp/sms_fwd_beat) )) 秒"
```

### 服务器端

```sh
systemctl status sms-server --no-pager
ss -lnt | grep -E '18111|18112'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18999/health
```

---

## 二、日志位置

| 位置 | 文件 | 说明 |
|---|---|---|
| CPE | `/tmp/net_watchdog.log` | 断网检测与恢复记录 |
| CPE | `/tmp/cpe_tunnel.log` | 隧道重连记录（超 64KB 自动轮转） |
| CPE | `/tmp/sms_fwd_beat` | 转发服务心跳（时间戳） |
| CPE | `/tmp/sms_fwd_seen` | 已推送短信的去重表（超 2000 行自动裁剪） |
| CPE | `logread \| grep sms_fwd` | 转发服务的运行日志 |
| CPE | `/root/cell_events.log` | 小区切换事件（超 3000 行自动裁剪） |
| 服务器 | `journalctl -u sms-server` | 短信网关服务 |
| 服务器 | `/var/log/nginx/<站点>-error.log` | nginx（大量扫描器探测属正常） |

---

## 三、常见故障处理

### 1. 有 IP 但上不了网

典型特征：`ip addr` 显示 `eth1` 有地址，但 `ping` 全丢包，`eth1` 收包数为 0。

**原因**：模组 USB 重新枚举，总线号/串口名变了，而 qmodem 配置写死。

```sh
/root/fix-modem.sh
```

### 2. 短信不转发

```sh
# 心跳还在更新吗？
echo "距今 $(( $(date +%s) - $(cat /tmp/sms_fwd_beat 2>/dev/null || echo 0) )) 秒"
# 超过 300 秒说明卡住了，看门狗会在下一轮自动重启；也可以手动：
/etc/init.d/sms_fwd restart

# 串口锁有没有残留？
ls -ld /var/lock/sms_serial        # 有就删掉：rmdir /var/lock/sms_serial
```

### 3. 远程后台打不开

```sh
# 隧道进程在不在
ps w | grep '[i]d_ed25519_tunnel'

# 重启隧道
/etc/init.d/cpe_tunnel restart
tail -20 /tmp/cpe_tunnel.log
```

### 4. 反复要求重新登录

nginx 里缺了 cookie 路径重写。确认站点配置包含：

```nginx
proxy_cookie_path /cgi-bin/luci/ /;
```

### 5. 静态资源 404

代理的 location 被正则 location 抢走了。确认用的是 `^~` 前缀：

```nginx
location ^~ /cpe/luci-static/ { ... }
```

---

## 四、换串口 / 换模组

所有脚本里的串口名都是**自动探测**的，正常情况下不需要改。

如果换了模组型号（非 FM350），需要调整 `cell_watch.sh` 里的 AT 指令
（`AT+GTCAINFO?` / `AT+GTCCINFO?` 是 Fibocom 私有指令）。

---

## 五、完整回滚

```sh
# CPE 端：停服务并移除
for s in sms_fwd sms_api cell_watch net_watchdog cpe_tunnel; do
    /etc/init.d/$s stop 2>/dev/null
    /etc/init.d/$s disable 2>/dev/null
    rm -f /etc/init.d/$s
done
rm -f /usr/bin/{sms_fwd_pushplus.sh,sms_api.py,cell_watch.sh,net_watchdog.sh,cpe_tunnel.sh,fix-modem.sh}
rm -f /etc/cpe_tunnel.conf /etc/pushplus.conf

# 服务器端
systemctl stop sms-server && systemctl disable sms-server
rm -f /etc/systemd/system/sms-server.service
rm -rf /opt/sms
rm -f /etc/nginx/snippets/{cpe-proxy.conf,sms-proxy.conf}
# 然后从站点配置里删掉那两行 include，再 reload nginx
```

---

## 六、安全维护

- **定期更换** `/opt/sms/config.json` 里的 `token`，并同步更新 CPE 的
  `/etc/pushplus.conf` 里的 `SERVER_TOKEN`
- 暴露在公网的后台**务必保留 Basic Auth**
- 建议服务器关闭 SSH 密码登录：
  ```sh
  # 先确认密钥能登录！
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  systemctl reload ssh
  ```
