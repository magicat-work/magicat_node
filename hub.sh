#!/bin/bash
# bash /root/hub.sh
# curl -Ls https://raw.githubusercontent.com/magicat-work/magicat_node/main/hub.sh | bash
[ "$(id -u)" -eq 0 ] || { echo "无 root 权限"; exit 1; }
set -Ee -o pipefail
trap 'echo "失败: 第 ${LINENO} 行 [${BASH_COMMAND}]" >&2' ERR
umask 077

# 参数
HUB_PY="/usr/local/bin/magicat_hub.py"
HUB_SVC="/etc/systemd/system/magicat-hub.service"
CF_BIN="/usr/local/bin/cloudflared"
CLEAN_BIN="/usr/local/bin/clean_user.sh"
NODES="/etc/magicat/nodes.tsv"
USERS="/etc/magicat/users.tsv"

# 安装
do_install() {
DEPS=()
command -v curl >/dev/null || DEPS+=(curl)
python3 -c 'import http.server' 2>/dev/null || DEPS+=(python3)
if [ "${#DEPS[@]}" -gt 0 ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y "${DEPS[@]}" >/dev/null || { echo "依赖安装失败: ${DEPS[*]}"; exit 1; }
fi
id magicat &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin magicat
mkdir -p /etc/magicat
chgrp magicat /etc/magicat
chmod 750 /etc/magicat
touch "$NODES" "$USERS"
chgrp magicat "$NODES" "$USERS"
chmod 640 "$NODES" "$USERS"

# 订阅与拉取
cat > "$HUB_PY" << 'PYEOF'
#!/usr/bin/env python3
import base64, hmac, json, os, re, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, urlparse, parse_qs

NODES = "/etc/magicat/nodes.tsv"
USERS = "/etc/magicat/users.tsv"
LISTEN = ("127.0.0.1", 3000)
SUB_RE = re.compile(r"^/sub/([A-Za-z0-9]{16,64})$")
DEAD = "ss://" + base64.b64encode(b"aes-256-gcm:0").decode().rstrip("=") + "@magicat.work:1#" + quote("订阅无效")
_lock  = threading.Lock()
_cache = {"stamp": None, "nodes": {}, "users": {}, "owned": {}}


# 按 mtime 缓存
def tables():
  stamp = tuple(os.stat(p).st_mtime_ns for p in (NODES, USERS))
  with _lock:
    if _cache["stamp"] == stamp:
      return _cache["nodes"], _cache["users"], _cache["owned"]
    nodes = {}
    with open(NODES) as f:
      for line in f:
        c = line.rstrip("\n").split("\t")
        if len(c) >= 5:
          nodes[c[0]] = {"key": c[1], "ip": c[2], "port": c[3], "pin": c[4]}
    users = {}
    with open(USERS) as f:
      for line in f:
        c = line.rstrip("\n").split("\t")
        if len(c) >= 3:
          users[c[2]] = (c[1], c[0])
    owned = {}
    for tok, (exp, node) in users.items():
      owned.setdefault(node, []).append(tok)
    for v in owned.values():
      v.sort()
    _cache.update(stamp=stamp, nodes=nodes, users=users, owned=owned)
    return nodes, users, owned


# 节点拉取
def fetch(key):
  if not key:
    return None
  nodes, users, owned = tables()
  hit = None
  for name, n in nodes.items():
    if hmac.compare_digest(n["key"], key):
      hit = name
  if hit is None:
    return None
  return [{"password": tok} for tok in owned.get(hit, [])]


# 订阅
def subscribe(token):
  nodes, users, owned = tables()
  rec = users.get(token)
  if rec is None:
    return None
  exp, node = rec
  n = nodes.get(node)
  if n is None:
    return None
  tag = quote(exp)
  return [
    f"hysteria2://{token}@{n['ip']}:{n['port']}/?pinSHA256={n['pin']}#{tag}_HY2",
    f"trojan://{token}@{n['ip']}:{n['port']}?pcs={n['pin']}#{tag}_Trojan",
  ]


class Handler(BaseHTTPRequestHandler):
  protocol_version = "HTTP/1.1"

  def log_message(self, *a):
    pass

  def send_response(self, code, message=None):
    self.send_response_only(code, message)
    self.send_header("Date", self.date_time_string())

  def reply(self, code, body, ctype="text/plain; charset=utf-8"):
    self.send_response(code)
    self.send_header("Content-Type", ctype)
    self.send_header("X-Content-Type-Options", "nosniff")
    self.send_header("Content-Length", str(len(body)))
    self.end_headers()
    if self.command != "HEAD":
      self.wfile.write(body)

  def do_GET(self):
    url = urlparse(self.path)

    if url.path == "/api/node":
      try:
        got = fetch((parse_qs(url.query).get("key") or [""])[0])
      except Exception:
        got = None
      if got is None:
        return self.reply(404, b"404 page not found\n")
      return self.reply(200, json.dumps(got).encode(), "application/json")

    m = SUB_RE.match(url.path)
    if m:
      try:
        uris = subscribe(m.group(1))
      except Exception:
        uris = None
      return self.reply(200, base64.b64encode(("\n".join(uris or [DEAD]) + "\n").encode()))

    self.reply(404, b"404 page not found\n")

  do_HEAD = do_POST = do_PUT = do_DELETE = do_OPTIONS = do_GET


if __name__ == "__main__":
  ThreadingHTTPServer(LISTEN, Handler).serve_forever()
PYEOF
chmod 755 "$HUB_PY"
python3 -c "import ast; ast.parse(open('${HUB_PY}').read())"

cat > "$HUB_SVC" << EOF
[Unit]
After=network.target

[Service]
User=magicat
ExecStart=/usr/bin/python3 ${HUB_PY}
Restart=on-failure
RestartSec=5
StandardOutput=null
StandardError=null
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
IPAddressDeny=any
IPAddressAllow=localhost
RestrictAddressFamilies=AF_INET AF_INET6
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# 过期处理: 过期标识置 000, 满 90 天删除
cat > "$CLEAN_BIN" << 'CLEANEOF'
#!/bin/bash
set -Ee -o pipefail
umask 077
USERS="/etc/magicat/users.tsv"
TMP="${USERS}.new"
D=$(TZ='Asia/Shanghai' date +%F)
P=$(TZ='Asia/Shanghai' date -d '-90 days' +%F)
awk -F'\t' -v OFS='\t' -v d="$D" -v p="$P" 'NF>=3 && $1=="000" && $2 < p {next} NF>=3 && $2 < d {$1="000"} {print}' "$USERS" > "$TMP"
if cmp -s "$TMP" "$USERS"; then rm -f "$TMP"; exit 0; fi
cp -a "$USERS" "${USERS}.bak"
chgrp magicat "$TMP"
chmod 640 "$TMP"
mv "$TMP" "$USERS"
CLEANEOF
chmod 700 "$CLEAN_BIN"
bash -n "$CLEAN_BIN"

cat > /etc/systemd/system/clean-user.service << EOF
[Unit]
ConditionPathExists=${USERS}

[Service]
Type=oneshot
ExecStart=${CLEAN_BIN}
StandardOutput=null
StandardError=null
EOF

cat > /etc/systemd/system/clean-user.timer << 'EOF'
[Timer]
OnCalendar=*-*-* 06:00:00 Asia/Shanghai
Persistent=true
AccuracySec=5min
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable magicat-hub clean-user.timer >/dev/null
systemctl restart magicat-hub clean-user.timer

# Cloudflare 隧道
curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "${CF_BIN}.new" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod 755 "${CF_BIN}.new"
systemctl stop cloudflared 2>/dev/null || true
if [ -x "$CF_BIN" ]; then "$CF_BIN" service uninstall >/dev/null 2>&1 || true; fi
mv -f "${CF_BIN}.new" "$CF_BIN"
"$CF_BIN" service install "$TOKEN" # 自身完成 daemon-reload / enable / start
ss -lnt 'sport = :3000'
}

# 卸载
do_uninstall() {
systemctl disable --now magicat-hub clean-user.timer 2>/dev/null || true
rm -f "$HUB_SVC" "$HUB_PY" "$CLEAN_BIN"
rm -f /etc/systemd/system/clean-user.service /etc/systemd/system/clean-user.timer
systemctl reset-failed magicat-hub clean-user.service clean-user.timer 2>/dev/null || true
systemctl disable --now cloudflared 2>/dev/null || true
if [ -x "$CF_BIN" ]; then "$CF_BIN" service uninstall >/dev/null 2>&1 || true; fi
rm -f "$CF_BIN" "${CF_BIN}.new"
rm -rf /etc/cloudflared /root/.cloudflared
systemctl daemon-reload
echo "卸载完成 (保留 /etc/magicat)"
}

# 入口
exec 3<> /dev/tty
cat >&3 << 'EOF'
[1] 安装
[2] 卸载
EOF
printf '请选择: ' >&3
read -r CHOICE <&3 || true
case "$CHOICE" in
  1) printf 'Tunnel Token: ' >&3; read -r TOKEN <&3 || true ;;
  2) exec 3>&-; do_uninstall; exit 0 ;;
  *) echo "无效输入: '${CHOICE}'"; exit 1 ;;
esac
exec 3>&-
[ -n "$TOKEN" ] || { echo "无输入"; exit 1; }
do_install
