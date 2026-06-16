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
SERVER_IP=$(curl -s https://api.ipify.org)
PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)
PORT=443

# 系统优化 (BBR)
grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || \
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || \
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p || true

# 目录 & 内核
mkdir -p /etc/sing-box
systemctl stop sing-box 2>/dev/null || true
curl -fL -o "$SINGBOX_BIN" "$DOWNLOAD_URL"
chmod +x "$SINGBOX_BIN"

# 自签名证书
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout "$SERVER_KEY" \
  -out    "$SERVER_CRT" \
  -days 3650 \
  -subj "/CN=cloudflare.com" \
  -addext "subjectAltName=IP:${SERVER_IP}"
chown nobody "$SERVER_KEY" "$SERVER_CRT"
chmod 600 "$SERVER_KEY" "$SERVER_CRT"
CERT_PIN=$(openssl x509 -in "$SERVER_CRT" -outform der | openssl dgst -sha256 -r | cut -d' ' -f1)
HY2_URI="hysteria2://${PASSWORD}@${SERVER_IP}:${PORT}/?sni=cloudflare.com&pinSHA256=${CERT_PIN}#Magicat_Node"
KEY_SHA256=$(openssl x509 -in "$SERVER_CRT" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64 -A)

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
      "users": [{"name": "user1", "password": "${PASSWORD}"}],
      "tls": {
        "enabled": true,
        "certificate_path": "${SERVER_CRT}",
        "key_path": "${SERVER_KEY}"
      },
      "masquerade": "https://www.cloudflare.com"
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
chown -R nobody /etc/sing-box
chmod 700 /etc/sing-box
chown nobody "$SINGBOX_CONF"
chown nobody "$SINGBOX_BIN"
chmod 600 "$SINGBOX_CONF"

# Systemd 服务
cat > /etc/systemd/system/sing-box.service << 'EOF'
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=1000000
LimitNPROC=65535
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=no
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
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
echo "# PC端配置"
echo "----------------"
printf '{"serverip":"%s","port": %d,"password":"%s","keysha256":"%s"}\n' "$SERVER_IP" "$PORT" "$PASSWORD" "$KEY_SHA256"
echo "----------------"
echo "# v2rayN/v2rayNG"
echo "----------------"
echo "${HY2_URI}"
echo "----------------"