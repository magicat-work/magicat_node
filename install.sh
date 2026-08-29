#!/bin/bash
# bash /root/install.sh
# curl -Ls https://raw.githubusercontent.com/magicat-work/magicat_node/main/install.sh | bash
[ "$(id -u)" -eq 0 ] || { echo "无 root 权限"; exit 1; }
set -Ee -o pipefail
trap 'echo "失败: 第 ${LINENO} 行 [${BASH_COMMAND}]" >&2' ERR
umask 077

# 参数
DOWNLOAD_URL="https://github.com/magicat-work/magicat_node/releases/download/amd64/sing-box"
HUB_API="https://sub.magicat.work"
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF="/etc/sing-box/config.json"
SERVER_KEY="/etc/sing-box/server.key"
SERVER_CRT="/etc/sing-box/server.crt"
AGENT_BIN="/usr/local/bin/magicat_agent.sh"
PROBE_BIN="/usr/local/bin/magicat_probe.py"
PORT=443

# 安装
do_install() {
MODE="${1:-}"
DEPS=()
command -v curl >/dev/null || DEPS+=(curl)
command -v jq >/dev/null || DEPS+=(jq)
python3 -c 'import http.server' 2>/dev/null || DEPS+=(python3)
if [ "${#DEPS[@]}" -gt 0 ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y "${DEPS[@]}" >/dev/null || { echo "依赖安装失败: ${DEPS[*]}"; exit 1; }
fi
SERVER_IP=$(curl -fsS --proto '=https' --tlsv1.2 --max-time 10 https://api.ipify.org)
id magicat &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin magicat

# 系统优化
cat > /etc/sysctl.d/99-singbox.conf << 'EOF'
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 131072 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.tcp_slow_start_after_idle=0
EOF
sysctl --system >/dev/null 2>&1 || true

# 目录 & 内核
mkdir -p /etc/sing-box
if [ "$MODE" = "update" ]; then
  SB_TAG=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --proto '=https' --tlsv1.2 --max-time 10 "https://github.com/SagerNet/sing-box/releases/latest" | sed 's#.*/tag/##')
  SB_VER="${SB_TAG#v}"
  curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 "https://github.com/SagerNet/sing-box/releases/download/${SB_TAG}/sing-box-${SB_VER}-linux-amd64.tar.gz" | tar -xzO --wildcards '*/sing-box' > "${SINGBOX_BIN}.new"
else
  curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "${SINGBOX_BIN}.new" "$DOWNLOAD_URL"
fi
chmod 755 "${SINGBOX_BIN}.new"

# 自签证书
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout "${SERVER_KEY}.new" -out "${SERVER_CRT}.new" -days 5475 -extensions ext \
  -config <(cat << EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = ${SERVER_IP}
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = IP:${SERVER_IP}
subjectKeyIdentifier = hash
EOF
)

# sing-box 配置
cat > "${SINGBOX_CONF}.new" << EOF
{
  "log": {"disabled": true},
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [],
      "ignore_client_bandwidth": true,
      "tls": {
        "enabled": true,
        "certificate_path": "${SERVER_CRT}",
        "key_path": "${SERVER_KEY}"
      },
      "masquerade": {
        "type": "proxy",
        "url": "http://127.0.0.1:8080"
      }
    },
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [],
      "tls": {
        "enabled": true,
        "alpn": ["http/1.1"],
        "certificate_path": "${SERVER_CRT}",
        "key_path": "${SERVER_KEY}"
      },
      "fallback": {
        "server": "127.0.0.1",
        "server_port": 8080
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

# 校验
jq --arg c "${SERVER_CRT}.new" --arg k "${SERVER_KEY}.new" '(.inbounds[].tls) |= (.certificate_path=$c|.key_path=$k)' "${SINGBOX_CONF}.new" | "${SINGBOX_BIN}.new" check -c /dev/stdin
chown magicat "${SERVER_KEY}.new" "${SERVER_CRT}.new" "${SINGBOX_CONF}.new"
mv "${SERVER_KEY}.new" "$SERVER_KEY"; mv "${SERVER_CRT}.new" "$SERVER_CRT"
mv "${SINGBOX_BIN}.new" "$SINGBOX_BIN"
mv "${SINGBOX_CONF}.new" "$SINGBOX_CONF"
chown magicat /etc/sing-box
chmod 700 /etc/sing-box

# Systemd 服务
cat > /etc/systemd/system/sing-box.service << 'EOF'
[Unit]
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
[Service]
User=magicat
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=1000000
LimitNPROC=65535
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=no
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectProc=invisible
ProcSubset=pid
SystemCallArchitectures=native
UMask=0077
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictNamespaces=true
LockPersonality=true
RestrictRealtime=true
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
MemoryDenyWriteExecute=true
RestrictSUIDSGID=true
RemoveIPC=true
ProtectClock=true
ProtectHostname=true
[Install]
WantedBy=multi-user.target
EOF

# 防探测服务：curl -k -sS -i https://<节点IP>:443
cat > "$PROBE_BIN" << 'PYEOF'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = ("127.0.0.1", 8080)


class Probe(BaseHTTPRequestHandler):
  protocol_version = "HTTP/1.1"

  def log_message(self, *a):
    pass

  def send_response(self, code, message=None):
    self.send_response_only(code, message)
    self.send_header("Date", self.date_time_string())

  def respond(self):
    body = b"404 page not found\n"
    self.send_response(404)
    self.send_header("Content-Type", "text/plain; charset=utf-8")
    self.send_header("X-Content-Type-Options", "nosniff")
    self.send_header("Content-Length", str(len(body)))
    self.end_headers()
    if self.command != "HEAD":
      self.wfile.write(body)

  do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = do_OPTIONS = respond


if __name__ == "__main__":
  ThreadingHTTPServer(LISTEN, Probe).serve_forever()
PYEOF
chmod 755 "$PROBE_BIN"
python3 -c "import ast; ast.parse(open('${PROBE_BIN}').read())"

cat > /etc/systemd/system/magicat-probe.service << EOF
[Unit]
After=network.target

[Service]
User=magicat
ExecStart=/usr/bin/python3 ${PROBE_BIN}
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

[Install]
WantedBy=multi-user.target
EOF

# 心跳 agent
cat > "$AGENT_BIN" << EOF
#!/bin/bash
set -Ee -o pipefail
umask 077
CONF="${SINGBOX_CONF}"
HUB_API="${HUB_API}"
NODE_KEY="${NODE_KEY}"
EOF

cat >> "$AGENT_BIN" << 'AGENTEOF'
NEW=$(curl -fsS --proto '=https' --tlsv1.2 --max-time 20 "${HUB_API}/api/node?key=${NODE_KEY}") || exit 0
jq -e 'type == "array"' <<< "$NEW" >/dev/null || exit 0
WANT=$(jq -cS 'sort_by(.password)' <<< "$NEW") || exit 0
HAVE=$(jq -cS '[.inbounds[] | select(.tag=="hy2-in").users[]] | sort_by(.password)' "$CONF")
[ "$WANT" != "$HAVE" ] || exit 0
cp -a "$CONF" "${CONF}.bak"
jq --argjson u "$WANT" '(.inbounds[] | select(.tag=="hy2-in" or .tag=="trojan-in").users) = $u' "$CONF" > "${CONF}.new"
/usr/local/bin/sing-box check -c "${CONF}.new"
chown magicat "${CONF}.new"
chmod 600 "${CONF}.new"
mv "${CONF}.new" "$CONF"
if ! systemctl restart sing-box; then
  cp -a "${CONF}.bak" "$CONF"
  chown magicat "$CONF"
  chmod 600 "$CONF"
  systemctl restart sing-box
  exit 1
fi
AGENTEOF
chmod 700 "$AGENT_BIN"
bash -n "$AGENT_BIN"

cat > /etc/systemd/system/magicat-agent.service << EOF
[Unit]
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${AGENT_BIN}
TimeoutStartSec=90
StandardOutput=null
StandardError=null
EOF

cat > /etc/systemd/system/magicat-agent.timer << 'EOF'
[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF

# 启动
systemctl daemon-reload
systemctl enable sing-box magicat-probe magicat-agent.timer >/dev/null
systemctl restart sing-box magicat-probe magicat-agent.timer
if [ "$MODE" = "update" ]; then echo "更新完成: sing-box ${SB_VER}"; else echo "安装完成"; fi
CERT_PIN=$(openssl x509 -in "$SERVER_CRT" -outform der | openssl dgst -sha256 -r | cut -d' ' -f1)
echo "---"
printf '%s %s %s %s\n' "$NODE_KEY" "$SERVER_IP" "$PORT" "$CERT_PIN"
echo "---"
}

# 卸载
do_uninstall() {
systemctl disable --now magicat-agent.timer magicat-probe 2>/dev/null || true
systemctl stop sing-box 2>/dev/null || true
systemctl disable sing-box 2>/dev/null || true
rm -f /etc/systemd/system/sing-box.service
rm -f /etc/systemd/system/magicat-agent.service /etc/systemd/system/magicat-agent.timer
rm -f /etc/systemd/system/magicat-probe.service
systemctl daemon-reload
systemctl reset-failed sing-box magicat-agent.service magicat-agent.timer magicat-probe 2>/dev/null || true
rm -f "$SINGBOX_BIN" "${SINGBOX_BIN}.new" "$AGENT_BIN" "$PROBE_BIN"
rm -rf /etc/sing-box
id magicat &>/dev/null && userdel magicat 2>/dev/null || true
rm -f /etc/sysctl.d/99-singbox.conf
sysctl --system >/dev/null 2>&1 || true
echo "卸载完成"
}

# 入口
exec 3<> /dev/tty
cat >&3 << 'EOF'
[1] 安装
[2] 更新
[3] 卸载
EOF
printf '请选择: ' >&3
read -r CHOICE <&3 || true
case "$CHOICE" in
  1|2) ;;
  3) exec 3>&-; do_uninstall; exit 0 ;;
  *) echo "无效输入: '${CHOICE}'"; exit 1 ;;
esac
exec 3>&-
NODE_KEY=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)
if [ "$CHOICE" = 1 ]; then do_install; else do_install update; fi
