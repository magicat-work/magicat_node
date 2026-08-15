#!/bin/bash
# bash /root/sub_server.sh
# curl -Ls https://raw.githubusercontent.com/magicat-work/magicat_node/main/sub_server.sh | bash

[ "$(id -u)" -eq 0 ] || { echo "无 root 权限"; exit 1; }
SUB_PY="/usr/local/bin/magicat_sub.py"
SUB_SVC="/etc/systemd/system/magicat-sub.service"
CF_BIN="/usr/local/bin/cloudflared"

set -Ee -o pipefail
trap 'echo "部署失败: 第 ${LINENO} 行 [${BASH_COMMAND}]" >&2' ERR
umask 077

# 安装
do_install() {
# Tunnel Token
exec 3<> /dev/tty
printf '请输入 Tunnel Token: ' >&3
read -r TOKEN <&3 || true
exec 3>&-
[ -n "$TOKEN" ] || { echo "无输入"; exit 1; }

# 公网 IP
SERVER_IP=$(curl -fsS --proto '=https' --tlsv1.2 --max-time 10 https://api.ipify.org)

if ! command -v python3 >/dev/null; then
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y python3-minimal >/dev/null
fi

# 订阅服务
cat > "$SUB_PY" << 'PYEOF'
#!/usr/bin/env python3
import base64, hashlib, json, re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote

CONF      = "/etc/sing-box/config.json"
CRT       = "/etc/sing-box/server.crt"
SERVER_IP = "__SERVER_IP__"
LISTEN    = ("127.0.0.1", 3000)


# 读取订阅参数: UUID 定长在前，密码在后，从左到右一次切开
PATH_RE = re.compile(
  r"^/sub/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
  r"([A-Za-z0-9]+)$")
P   = 2**255 - 19 # X25519 曲线参数
A24 = 121665

# 占位节点
DEAD = ("ss://" + base64.b64encode(b"aes-256-gcm:0").decode().rstrip("=")
  + "@magicat.work:1#" + quote("订阅无效"))


# 证书指纹
def cert_pin():
  with open(CRT) as f:
    der = base64.b64decode("".join(l.strip() for l in f if "CERTIFICATE" not in l))
  return hashlib.sha256(der).hexdigest()


# X25519(clamp(priv), 9) —— RFC 7748 蒙哥马利阶梯，纯 Python 不起子进程
def x25519_base(priv):
  k = bytearray(priv)
  k[0] &= 248; k[31] &= 127; k[31] |= 64
  k = int.from_bytes(k, "little")
  x1, x2, z2, x3, z3, swap = 9, 1, 0, 9, 1, 0
  for t in range(254, -1, -1):
    kt = (k >> t) & 1
    swap ^= kt
    if swap:
      x2, x3 = x3, x2
      z2, z3 = z3, z2
    swap = kt
    a  = (x2 + z2) % P; aa = a * a % P
    b  = (x2 - z2) % P; bb = b * b % P
    e  = (aa - bb) % P
    c  = (x3 + z3) % P; d  = (x3 - z3) % P
    da = d * a % P;     cb = c * b % P
    x3 = (da + cb) % P; x3 = x3 * x3 % P
    z3 = (da - cb) % P; z3 = x1 * (z3 * z3 % P) % P
    x2 = aa * bb % P
    z2 = e * ((aa + A24 * e) % P) % P
  if swap:
    x2, x3 = x3, x2
    z2, z3 = z3, z2
  return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, "little")


# REALITY 私钥反推公钥 (pbk)
def reality_pubkey(priv):
  raw = base64.urlsafe_b64decode(priv + "=" * (-len(priv) % 4))
  return base64.urlsafe_b64encode(x25519_base(raw)).decode().rstrip("=")


# uuid 与密码必须属于同一个用户，否则返回 None
def build(uuid, pw):
  with open(CONF) as f:
    conf = json.load(f)
  inb = {i["tag"]: i for i in conf["inbounds"]}
  hy, vl = inb["h2-in"], inb["vless-in"]

  idx = next((i for i, u in enumerate(vl["users"]) if u["uuid"] == uuid), None)
  if idx is None or idx >= len(hy["users"]):
    return None
  if hy["users"][idx].get("password") != pw:
    return None

  name = vl["users"][idx]["name"]
  port = hy["listen_port"]
  sni  = vl["tls"]["server_name"]
  sid  = vl["tls"]["reality"]["short_id"][0]
  pbk  = reality_pubkey(vl["tls"]["reality"]["private_key"])

  return [
    f"hysteria2://{pw}@{SERVER_IP}:{port}/?pinSHA256={cert_pin()}#{name}_HY2",
    f"vless://{uuid}@{SERVER_IP}:{port}?encryption=none&flow=xtls-rprx-vision"
    f"&security=reality&sni={sni}&fp=chrome&pbk={pbk}&sid={sid}"
    f"&type=tcp#{name}_VLESS",
  ]


class Handler(BaseHTTPRequestHandler):
  protocol_version = "HTTP/1.1"

  def log_message(self, *a):
    pass

  def do_GET(self):
    m = PATH_RE.match(self.path)
    uris = (build(m.group(1), m.group(2)) if m else None) or [DEAD]
    body = base64.b64encode(("\n".join(uris) + "\n").encode())
    self.send_response(200)
    self.send_header("Content-Type", "text/plain; charset=utf-8")
    self.send_header("Content-Length", str(len(body)))
    self.end_headers()
    self.wfile.write(body)


if __name__ == "__main__":
  ThreadingHTTPServer(LISTEN, Handler).serve_forever()
PYEOF
sed -i "s/__SERVER_IP__/${SERVER_IP}/" "$SUB_PY"
chmod 755 "$SUB_PY"
python3 -c "import ast; ast.parse(open('${SUB_PY}').read())"

# systemd service
cat > "$SUB_SVC" << EOF
[Unit]
Description=magicat subscription service
ConditionPathExists=/etc/sing-box/config.json

[Service]
User=magicat
ExecStart=/usr/bin/python3 ${SUB_PY}
Restart=no
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

systemctl daemon-reload
systemctl enable magicat-sub >/dev/null
systemctl restart magicat-sub

# Cloudflare 隧道
curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "${CF_BIN}.new" \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod 755 "${CF_BIN}.new"
systemctl stop cloudflared 2>/dev/null || true
if [ -x "$CF_BIN" ]; then "$CF_BIN" service uninstall >/dev/null 2>&1 || true; fi
mv -f "${CF_BIN}.new" "$CF_BIN"
"$CF_BIN" service install "$TOKEN" # 自身完成 daemon-reload / enable / start

# 端口检查
ss -lnt 'sport = :3000'
}

# 卸载
do_uninstall() {
systemctl disable --now magicat-sub 2>/dev/null || true
rm -f "$SUB_SVC" "$SUB_PY"
systemctl reset-failed magicat-sub 2>/dev/null || true
systemctl disable --now cloudflared 2>/dev/null || true
if [ -x "$CF_BIN" ]; then "$CF_BIN" service uninstall >/dev/null 2>&1 || true; fi
rm -f "$CF_BIN" "${CF_BIN}.new"
rm -rf /etc/cloudflared /root/.cloudflared
systemctl daemon-reload
echo "订阅服务已清理"
}

# 入口
exec 3<> /dev/tty
cat >&3 << 'EOF'
[1] 安装
[2] 卸载
EOF
printf '请选择: ' >&3
read -r CHOICE <&3 || true
exec 3>&-
case "$CHOICE" in
  1) do_install ;;
  2) do_uninstall ;;
  *) echo "无效输入: '${CHOICE}'"; exit 1 ;;
esac