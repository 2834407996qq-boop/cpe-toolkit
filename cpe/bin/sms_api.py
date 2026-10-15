#!/usr/bin/env python3
# CPE 侧短信 API：供服务器经反向隧道拉取实时短信 / 发短信
#
# 串口独占问题：/dev/ttyUSB3 同时被 ubus-at-daemon(qmodem)、sms_fwd_pushplus.sh
# 和本服务访问。并发读写会让 AT 响应错乱（"command error" / 无响应）。
# 对策：
#   1) 本服务与 sms_fwd 共用 mkdir 原子锁，串行化彼此的访问
#   2) 发送操作整体持锁 + 内部重试（对上层的 ubus-at-daemon 干扰做容错）
import json, subprocess, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 18998
PORTS = ['/dev/ttyUSB3', '/dev/ttyUSB1']
LOCKDIR = '/var/lock/sms_serial'
STALE = 90            # 锁超过 90 秒视为残留
SEND_CMD_TIMEOUT = 30
RECV_CMD_TIMEOUT = 20


def acquire(timeout):
    end = time.time() + timeout
    while time.time() < end:
        try:
            os.mkdir(LOCKDIR)
            return True
        except FileExistsError:
            try:
                if time.time() - os.path.getmtime(LOCKDIR) > STALE:
                    os.rmdir(LOCKDIR)
                    continue
            except Exception:
                pass
            time.sleep(0.5)
        except Exception:
            return False
    return False


def release():
    try:
        os.rmdir(LOCKDIR)
    except Exception:
        pass


def _raw(cmd, timeout):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ''


def _ok(out):
    return ('sucessfully' in out) or ('successfully' in out)


def locked_call(cmd, wait, cmd_timeout):
    """持锁执行单条串口命令。"""
    if not acquire(wait):
        return ''
    try:
        return _raw(cmd, cmd_timeout)
    finally:
        release()


def recv():
    for p in PORTS:
        out = locked_call(['sms_tool_q', '-d', p, '-j', 'recv'], 15, RECV_CMD_TIMEOUT)
        if out.strip().startswith('{'):
            return out
    return '{"msg":[]}'


def send(to, txt):
    """持锁执行一次发送。

    不做盲目重试：AT 命令超时并不代表短信没发出去，重试可能造成重复扣费。
    只有第一个端口完全无输出时才换下一个端口。
    """
    if not acquire(20):
        return {'ok': False, 'out': 'busy', 'msg': '串口忙，请稍后重试'}
    try:
        last = ''
        for p in PORTS:
            last = _raw(['sms_tool_q', '-d', p, 'send', to, txt],
                        SEND_CMD_TIMEOUT).strip()
            if _ok(last):
                return {'ok': True, 'out': last}
            if last:
                break          # 有输出说明模块已回应（错误信息），不再换端口
        return {'ok': False, 'out': last or 'no response',
                'msg': '模块无响应，请稍后重试'}
    finally:
        release()


class H(BaseHTTPRequestHandler):
    def _s(self, c, b):
        b = b.encode()
        self.send_response(c)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == '/sms':
            self._s(200, recv())
        elif self.path == '/ping':
            self._s(200, '{"ok":true}')
        else:
            self._s(404, '{}')

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        try:
            d = json.loads(self.rfile.read(n) or b'{}')
        except Exception:
            return self._s(400, '{"error":"bad json"}')

        if self.path == '/send':
            to = (d.get('to') or '').strip()
            txt = (d.get('text') or '').strip()
            if not to or not txt:
                return self._s(400, '{"error":"missing to/text"}')
            self._s(200, json.dumps(send(to, txt), ensure_ascii=False))
        else:
            self._s(404, '{}')

    def log_message(self, *a):
        pass


if __name__ == '__main__':
    # 多线程：避免"发送中"把"同步原文"请求阻塞住（串口访问仍由文件锁串行化）
    ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
