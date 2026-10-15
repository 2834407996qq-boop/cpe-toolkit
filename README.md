# cpe-toolkit

> 给「CPE + 4G/5G 模组」这套家用上网方案补上缺失的那几块：
> **短信转发成网页、异地访问后台、断网自愈、模组端口自愈。**

English: A small toolkit for CPE routers (OpenWrt/QWRT + Fibocom FM350-GL and similar
modems): forward SMS to a self-hosted web inbox, expose LuCI behind NAT via a reverse
SSH tunnel, and self-heal the network and the modem's serial port when things break.

---

## 背景 / 为什么会有这个项目

用 CPE 插流量卡当宽带的人，大概率都遇到过这几件事：

| 痛点 | 现象 |
|---|---|
| 短信看不到 | 卡在设备里，出门在外收不到验证码 |
| 后台进不去 | CPE 在运营商 NAT 后，没有公网 IP |
| 断网没人管 | 半夜断了，要回家重启 |
| 拔插就失联 | 模组是 USB 设备，重新枚举后串口名会变，配置写死就废了 |

这个项目把这几件事都解决了，全部经过长期实机验证（累计运行数月）。

---

## 功能

### 1. 短信网关（自建网页版收件箱）

- CPE 收到短信 → **同时**推送 PushPlus（微信）**和**你自己的域名
- 自建 Web 界面：卡片流、Apple 液态玻璃风格、深色模式、移动端适配
- **验证码一键复制**，自动高亮识别
- 分类独立：验证码 / 银行 / 支付 / 通知，各自计数
- 历史永久留存（存服务器 SQLite，不占用 CPE 闪存）
- 支持**发短信**（实验性，受串口独占限制）
- 双通道：推送为主 + 定时拉取兜底，推送漏了也能补回来

### 2. 异地访问 LuCI

- CPE 主动向你的服务器建立 SSH 反向隧道，穿透运营商 NAT
- 通过 `https://你的域名/cpe/` 访问路由器后台
- 断线自动重连，开机自启

### 3. 网络看门狗（三级自愈）

```
断网 → 连续 3 次探测失败
  ├─ L0 模组端口体检：配置指向的 USB 位置/串口失效 → 自动修正并重拨
  ├─ L1 重建拨号接口
  ├─ L2 重启拨号服务
  └─ L3 模组射频复位
```

### 4. 短信转发服务自愈

- 主循环写心跳文件，看门狗发现心跳超时就重启它
- 解决「进程还活着但已经不干活」这类最难发现的静默故障

### 5. 模组端口自愈（`fix-modem.sh`）

拔插模组后 USB 总线号会变（`2-1.2` → `3-1.2`），AT 串口也会变（`ttyUSB3` → `ttyUSB1`），
而 qmodem 的配置是写死的 —— 表现为**有 IP 但上不了网，且 `eth1` 收包数为 0**。

一条命令修好：

```sh
/root/fix-modem.sh
```

### 6. 驻留小区监控

长期记录设备驻留过的小区（PCI / TAC / RSRP），用于判断基站归属和信号质量。

---

## 架构

```
                    ┌──────────────── 你的服务器（有公网 IP）────────────────┐
                    │                                                      │
  手机/电脑 ──HTTPS─▶ nginx ──┬─ /cpe/  ─┐                                   │
                    │         ├─ /text  ─┼─▶ 127.0.0.1:18999  sms_server.py │
                    │         └─ /api/* ─┘        │                         │
                    │                             ▼                        │
                    │                     127.0.0.1:18112 ◀──┐              │
                    │                     127.0.0.1:18111 ◀──┼──┐           │
                    └─────────────────────────────────────────┼──┼───────────┘
                                                              │  │
                                        SSH 反向隧道（CPE 主动连出，穿透 NAT）
                                                              │  │
                    ┌─────────────────────────────────────────┼──┼───────────┐
                    │ 家用 CPE（OpenWrt）                      │  │           │
                    │                                          │  │           │
                    │   cpe_tunnel.sh ─────────────────────────┘  │           │
                    │                                             │           │
                    │   sms_api.py ──────── 127.0.0.1:18998 ◀─────┘           │
                    │        │                                                │
                    │        ▼                                                │
                    │   /dev/ttyUSBn  ──▶  FM350-GL 模组  ──▶  SIM 卡         │
                    │        ▲                                                │
                    │        │                                                │
                    │   sms_fwd_pushplus.sh ──┬──▶ PushPlus（微信）            │
                    │                         └──▶ 服务器 /api/sms             │
                    │                                                          │
                    │   net_watchdog.sh   网络自愈 + 转发服务心跳监控          │
                    │   cell_watch.sh     驻留小区记录                         │
                    └──────────────────────────────────────────────────────────┘
```

---

## 快速开始

### 服务器端

```bash
git clone https://github.com/YOUR_USERNAME/cpe-toolkit.git
cd cpe-toolkit
bash install/install-server.sh
```

安装完会打印**随机生成的访问密码**和**上报令牌**，请立刻保存。

然后按提示，在你的 nginx 站点 `server{}` 里、`location /` **之前**加入：

```nginx
include /etc/nginx/snippets/cpe-proxy.conf;
include /etc/nginx/snippets/sms-proxy.conf;
```

```bash
nginx -t && systemctl reload nginx
```

### CPE 端

把仓库传到 CPE（或直接 clone），然后：

```sh
cd cpe-toolkit
sh install/install-cpe.sh
```

安装脚本会打印**隧道公钥**，把它加到服务器的 `~/.ssh/authorized_keys`：

```bash
# 在服务器上执行
echo "ssh-ed25519 AAAA... cpe-tunnel" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

然后编辑两个配置并启动：

```sh
vi /etc/cpe_tunnel.conf    # 填 TUNNEL_SERVER=root@你的服务器
vi /etc/pushplus.conf      # 填 TOKEN / SERVER_URL / SERVER_TOKEN

/etc/init.d/cpe_tunnel start
/etc/init.d/sms_fwd start
/etc/init.d/sms_api start
/etc/init.d/net_watchdog start
/etc/init.d/cell_watch start
```

访问：

- 路由器后台 `https://你的域名/cpe/`
- 短信页面 `https://你的域名/text`

---

## 组件说明

| 文件 | 位置 | 作用 |
|---|---|---|
| `cpe/bin/sms_fwd_pushplus.sh` | CPE | 轮询短信 → PushPlus + 自建网关 |
| `cpe/bin/sms_api.py` | CPE | 短信 API（拉取 / 发送），带串口互斥锁 |
| `cpe/bin/net_watchdog.sh` | CPE | 网络三级自愈 + 转发服务心跳监控 |
| `cpe/bin/cell_watch.sh` | CPE | 驻留小区记录 |
| `cpe/bin/cpe_tunnel.sh` | CPE | SSH 反向隧道保活 |
| `cpe/bin/fix-modem.sh` | CPE | 拔插模组后一键修端口 |
| `server/sms_server.py` | 服务器 | 短信网关（接收 / 存储 / 展示 / 发送） |
| `server/sms_ui.html` | 服务器 | 短信 Web 界面 |
| `server/nginx/*.conf` | 服务器 | 反向代理片段 |
| `conf/*.example` | 两端 | 配置模板 |

---

## 踩坑记录（这部分可能比代码更值钱）

这些都是实际撞出来、并且已修复的问题，记录在此供参考。

### 1. 串口是独占资源，多个进程抢会错乱

`ubus-at-daemon`（qmodem 用）、`sms_fwd`、`sms_api` 都会访问 `/dev/ttyUSBn`。
并发读写会让 AT 响应错乱，表现是 `sms not sent, command error` 或干脆无响应。

**对策**：用 `mkdir` 原子操作做跨进程锁（shell 和 Python 共用同一个锁目录）。

### 2. `sms_tool_q delete` 没有超时，会永久阻塞

这是最坑的一个 —— 串口异常时它永不返回，导致整个轮询循环停摆。
**进程还活着，但已经不干活了**，procd 的自动重启完全用不上（它没退出）。

结果：**静默停摆 2 天没人发现。**

**对策**：
- 用「后台执行 + 超时 kill」给所有串口命令兜底
- 主循环写心跳文件，看门狗发现心跳超时就重启服务

### 3. 隧道远端命令用 `sleep 86400` 会每 24 小时自断

日志显示每天同一时刻断开一次、退出码 0 —— 因为 `sleep 86400` 到点了。

**对策**：远端改用 `while true; do sleep 3600; done`。

### 4. nginx 反代 LuCI：`^~` 前缀是必须的

如果站点里存在 `location ~* \.(css|js|png...)$` 这类**正则** location，
它的优先级高于普通前缀 location，会把你反代的静态资源全部抢走 → 404。

**对策**：所有代理 location 都用 `^~` 前缀。

### 5. LuCI 的 cookie path 导致「每点一个菜单就要重新登录」

LuCI 下发 `Set-Cookie: sysauth=...; path=/cgi-bin/luci/`，
而你的访问路径是 `/cpe/cgi-bin/luci/` —— 路径不匹配，浏览器根本不发这个 cookie。

`sub_filter` 只能改 HTML 正文，**改不了响应头**，所以必须单独处理：

```nginx
proxy_cookie_path /cgi-bin/luci/ /;
```

### 6. 超时链必须自洽

CPE 发送最坏耗时 ≈ 80s（等锁 20s + 命令 30s × 2 个候选端口），
如果服务器只等 45s、nginx 默认只等 60s，就会出现
**「CPE 其实发出去了，网页却报不可达」**的假失败。

**对策**：服务器 75s、nginx 120s。

### 7. USB 模组重新枚举会改变总线号和串口名

拔插模组后，设备可能从 `4-1.2` 跑到 `3-1.2`，AT 串口从 `ttyUSB3` 变成 `ttyUSB1`。
而 qmodem 的配置是写死的 → **有 IP 但完全不通，`eth1` 收包数为 0**。

**对策**：
- 所有脚本里的串口名一律**自动探测**，不写死
- 提供 `fix-modem.sh` 一键修复，并让看门狗在断网时自动调用

### 8. 已推送过的短信不删除会撑爆 SIM 卡

去重表命中后直接 `continue`，导致卡里的旧短信永远不被清理，最终 SIM 存储满
（通常 100 条），新短信进不来。

**对策**：命中去重表时也要执行删除。

---

## 排障

| 现象 | 排查 |
|---|---|
| 有 IP 但上不了网，`eth1` 收包为 0 | 跑 `/root/fix-modem.sh` |
| 短信不转发 | `tail -20 /tmp/net_watchdog.log`；看心跳 `/tmp/sms_fwd_beat` 是否在更新 |
| 远程后台打不开 | CPE 上 `tail -20 /tmp/cpe_tunnel.log`；确认进程在 |
| 短信页面能开但发不出短信 | 正常现象，见下方「已知限制」 |
| 反复要求重新登录 | 确认 nginx 里有 `proxy_cookie_path /cgi-bin/luci/ /;` |

---

## 已知限制

- **发短信不可靠**。`sms_tool_q` 不支持通过 ubus 代理，只能直接抢占串口，
  而 qmodem 的守护进程也在用同一个串口。成功率依赖时序，属于工具本身的限制。
  收短信与转发不受影响。
- 不同模组/固件的 AT 指令集差异较大，本项目在 **FM350-GL + QWRT 24.10** 上验证，
  其他模组需要调整 `cell_watch.sh` 里的 AT 指令。
- nginx 反代方案需要站点能加 `server{}` 配置；纯静态托管不适用。

---

## 安全提示

- 暴露到公网的管理后台**务必加认证**，本项目默认使用 nginx Basic Auth
- 上报接口用独立的 token 鉴权（示例配置里的 `token`）
- **不要把 `/etc/pushplus.conf`、`config.json` 提交进版本库**（`.gitignore` 已覆盖）
- 建议给服务器关闭密码登录、改用密钥

---

## 许可

MIT License，见 [LICENSE](LICENSE)。

## 贡献

欢迎提 Issue / PR。如果你在其他模组上跑通了，欢迎补充一份适配说明。
