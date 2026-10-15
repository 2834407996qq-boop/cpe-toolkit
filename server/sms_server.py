#!/usr/bin/env python3
"""
sms_server.py —— 自建短信网关（服务器端）

功能：
  POST /api/sms    接收 CPE 上报的短信（Bearer token 鉴权，落 SQLite）
  GET  /text       短信 Web 界面（Apple 风格，见 sms_ui.html）
  GET  /api/list   列表 JSON（供前端轮询）
  POST /api/sync   经反向隧道拉取 CPE 当前短信，补齐推送漏掉的
  POST /api/send   经反向隧道让 CPE 发短信

配置（优先环境变量，其次 /opt/sms/config.json）：
  SMS_DB      数据库路径          默认 /opt/sms/db/sms.db
  SMS_TOKEN   上报鉴权令牌        必填
  SMS_CPE     CPE 短信 API 地址   默认 http://127.0.0.1:18112
  SMS_PORT    监听端口            默认 18999
  SMS_UI      UI 文件路径         默认 /opt/sms/ui.html
"""
import os, json, sqlite3, hashlib, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


def _load_conf():
    conf = {}
    path = os.environ.get('SMS_CONFIG', '/opt/sms/config.json')
    try:
        with open(path, encoding='utf-8') as f:
            conf = json.load(f)
    except Exception:
        pass
    return conf


_CFG = _load_conf()


def cfg(key, env, default=None):
    return os.environ.get(env) or _CFG.get(key) or default


DB = cfg('db', 'SMS_DB', '/opt/sms/db/sms.db')
TOKEN = cfg('token', 'SMS_TOKEN')
CPE = cfg('cpe', 'SMS_CPE', 'http://127.0.0.1:18112')
PORT = int(cfg('port', 'SMS_PORT', 18999))
UI_PATH = cfg('ui', 'SMS_UI', '/opt/sms/ui.html')

if not TOKEN:
    raise SystemExit('缺少上报令牌：请设置环境变量 SMS_TOKEN 或 /opt/sms/config.json 中的 token')


def db():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    c = sqlite3.connect(DB)
    c.row_factory = sqlite3.Row
    return c


def init():
    c = db()
    c.execute('''CREATE TABLE IF NOT EXISTS sms(
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        md5         TEXT UNIQUE,          -- 内容指纹，用于去重
        sender      TEXT,
        content     TEXT,
        ts          TEXT,                 -- 短信自带时间
        parts       INTEGER DEFAULT 1,    -- 长短信段数
        received_at TEXT DEFAULT (datetime('now','localtime')),
        source      TEXT)                 -- push=CPE 主动推送, sync=服务器拉取
    ''')
    c.commit()
    c.close()


def md5(s):
    return hashlib.md5((s or '').encode()).hexdigest()


def merge(msgs):
    """把长短信的多个分段合并成一条。

    分组键 = reference + timestamp：分段同 reference 同秒到达；
    reference 会被循环复用，必须配合 timestamp 才能区分无关短信。
    """
    g = {}
    for m in msgs:
        g.setdefault((m.get('reference'), m.get('timestamp')), []).append(m)
    out = []
    for v in g.values():
        v.sort(key=lambda x: x.get('part') or 0)
        out.append({'sender': v[0].get('sender'),
                    'content': ''.join(x.get('content') or '' for x in v),
                    'ts': v[0].get('timestamp'),
                    'parts': len(v)})
    return out


def UI():
    try:
        with open(UI_PATH, encoding='utf-8') as f:
            return f.read()
    except Exception:
        return '<h1>SMS UI missing</h1>'


class Handler(BaseHTTPRequestHandler):
    server_version = 'sms-gateway/1.0'

    def _send(self, code, body, ctype='application/json; charset=utf-8'):
        b = body.encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(b)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(b)

    def _body(self):
        n = int(self.headers.get('Content-Length') or 0)
        return self.rfile.read(n)

    # ---------------- GET ----------------
    def do_GET(self):
        p = urlparse(self.path).path
        if p in ('/text', '/text/'):
            self._send(200, UI(), 'text/html; charset=utf-8')
        elif p == '/api/list':
            c = db()
            rows = c.execute('SELECT * FROM sms ORDER BY id DESC LIMIT 500').fetchall()
            c.close()
            self._send(200, json.dumps([dict(r) for r in rows], ensure_ascii=False))
        elif p == '/health':
            self._send(200, '{"ok":true}')
        else:
            self._send(404, '{}')

    # ---------------- POST ----------------
    def do_POST(self):
        p = urlparse(self.path).path
        raw = self._body()
        if p == '/api/sms':
            self._ingest(raw)
        elif p == '/api/sync':
            self._send(200, json.dumps({'synced': self.sync()}))
        elif p == '/api/send':
            try:
                d = json.loads(raw)
            except Exception:
                return self._send(400, '{"error":"bad json"}')
            r = self.cpe('/send', d)
            self._send(200, r or '{"error":"CPE unreachable"}')
        else:
            self._send(404, '{}')

    def _ingest(self, raw):
        try:
            d = json.loads(raw)
        except Exception:
            return self._send(400, '{"error":"bad json"}')
        if d.get('token') != TOKEN:
            return self._send(403, '{"error":"bad token"}')
        c = db()
        c.execute('INSERT OR IGNORE INTO sms(md5,sender,content,ts,parts,source) VALUES(?,?,?,?,?,?)',
                  (d.get('md5') or md5(d.get('content')), d.get('sender'),
                   d.get('content'), d.get('ts'), d.get('parts', 1), 'push'))
        c.commit()
        c.close()
        self._send(200, '{"ok":1}')

    # ---------------- 与 CPE 通信 ----------------
    def cpe(self, path, data=None):
        url = CPE + path
        try:
            if data is None:
                return urllib.request.urlopen(url, timeout=12).read().decode()
            req = urllib.request.Request(
                url, data=json.dumps(data).encode(),
                headers={'Content-Type': 'application/json'})
            # 发短信耗时链：CPE 等锁最长 20s + 命令 30s × 2 个候选端口 ≈ 80s。
            # 必须给足余量，否则 CPE 已发出、前端却报"不可达"。
            return urllib.request.urlopen(req, timeout=75).read().decode()
        except Exception:
            return None

    def sync(self):
        raw = self.cpe('/sms')
        if not raw:
            return 0
        try:
            msgs = json.loads(raw).get('msg', [])
        except Exception:
            return 0
        n = 0
        c = db()
        for m in merge(msgs):
            cur = c.execute(
                'INSERT OR IGNORE INTO sms(md5,sender,content,ts,parts,source) VALUES(?,?,?,?,?,?)',
                (md5(m['content']), m['sender'], m['content'], m['ts'], m['parts'], 'sync'))
            n += 1 if cur.rowcount else 0
        c.commit()
        c.close()
        return n

    def log_message(self, *a):
        pass


if __name__ == '__main__':
    init()
    ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
