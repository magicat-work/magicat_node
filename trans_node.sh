#!/bin/bash
set -e
trap 'echo "部署失败 (第 ${LINENO} 行)"; exit 1' ERR
[ "$(id -u)" -eq 0 ] || exit 1
umask 077

node_server_ip="$1"
node_port="$2"
node_password="$3"
node_keysha256="$4"

# 参数
DOWNLOAD_URL="https://github.com/magicat-work/magicat_node/releases/download/amd64/sing-box"
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF="/etc/sing-box/config.json"
SERVER_KEY="/etc/sing-box/server.key"
SERVER_CRT="/etc/sing-box/server.crt"
SERVER_IP=$(curl -fsS --proto '=https' --tlsv1.2 --max-time 10 https://api.ipify.org)
PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
PORT=443
REALITY_SNI="www.cloudflare.com"

# 专用系统用户
id magicat &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin magicat

# 系统优化 (BBR + UDP 缓冲)
cat > /etc/sysctl.d/99-singbox.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.core.rmem_default=1048576
net.core.wmem_default=1048576
EOF
sysctl --system

# 目录 & 内核
mkdir -p /etc/sing-box
systemctl stop sing-box 2>/dev/null || true
curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$SINGBOX_BIN" "$DOWNLOAD_URL"
chmod 755 "$SINGBOX_BIN"

# 自签名证书
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout "$SERVER_KEY" \
  -out    "$SERVER_CRT" \
  -days 3650 \
  -subj "/CN=cloudflare.com" \
  -addext "subjectAltName=IP:${SERVER_IP}"
chown magicat "$SERVER_KEY" "$SERVER_CRT"
chmod 600 "$SERVER_KEY" "$SERVER_CRT"
CERT_PIN=$(openssl x509 -in "$SERVER_CRT" -outform der | openssl dgst -sha256 -r | cut -d' ' -f1)
HY2_URI="hysteria2://${PASSWORD}@${SERVER_IP}:${PORT}/?sni=cloudflare.com&pinSHA256=${CERT_PIN}#Magicat_HY2"
KEY_SHA256=$(openssl x509 -in "$SERVER_CRT" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64 -A)

# VLESS + REALITY 参数
UUID=$("$SINGBOX_BIN" generate uuid)
REALITY_KEYS=$("$SINGBOX_BIN" generate reality-keypair)
REALITY_PRIVATE=$(echo "$REALITY_KEYS" | awk '/PrivateKey/{print $2}')
REALITY_PUBLIC=$(echo "$REALITY_KEYS" | awk '/PublicKey/{print $2}')
SHORT_ID=$(openssl rand -hex 8)
VLESS_URI="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp#Magicat_VLESS"

# sing-box 配置
cat > "$SINGBOX_CONF" << EOF
{
  "log": {"disabled": true},
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "h2-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [{"name": "magicat_hy2", "password": "${PASSWORD}"}],
      "tls": {
        "enabled": true,
        "certificate_path": "${SERVER_CRT}",
        "key_path": "${SERVER_KEY}"
      },
      "masquerade": "https://www.cloudflare.com"
    },
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [{"name": "magicat_vless", "uuid": "${UUID}", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_SNI}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "server": "${node_server_ip}",
      "server_port": ${node_port},
      "password": "${node_password}",
      "tls": {
        "enabled": true,
        "server_name": "cloudflare.com",
        "certificate_public_key_sha256": "${node_keysha256}",
        "insecure": true
      }
    }
  ]
}
EOF
chown -R magicat /etc/sing-box
chmod 700 /etc/sing-box
chown magicat "$SINGBOX_CONF"
chmod 600 "$SINGBOX_CONF"

# Systemd 服务
cat > /etc/systemd/system/sing-box.service << 'EOF'
[Unit]
Description=sing-box Service
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

# 启动
systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box
systemctl status sing-box --no-pager

# 客户端信息
echo "----------------"
echo "# Magicat配置"
echo "----------------"
printf '{"serverip":"%s", "port": %d, "password":"%s","keysha256":"%s"}\n' "$SERVER_IP" "$PORT" "$PASSWORD" "$KEY_SHA256"
echo "----------------"
echo "# v2rayN/v2rayNG"
echo "----------------"
echo "${HY2_URI}"
echo "----------------"
echo "${VLESS_URI}"
echo "----------------"

# 运行 bash install.sh