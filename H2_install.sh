#!/bin/bash
set -e

# 参数
DOWNLOAD_URL="https://github.com/MagicatAI/magicat_node/releases/download/node_v1.0.0.0/sing-box"
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF="/etc/sing-box/config.json"
SERVER_KEY="/etc/sing-box/server.key"
SERVER_CRT="/etc/sing-box/server.crt"
SERVER_IP=$(curl -s https://api.ipify.org)
PASSWORD=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)

# 系统优化 (BBR)
grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf || {
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
}
sysctl -p

# 目录 & 内核
mkdir -p /etc/sing-box
systemctl stop sing-box || true
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

# 提取公钥计算 SHA256
SERVER_CRT_PIN=$(openssl x509 -in certificate.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64)

# sing-box 配置
cat > "$SINGBOX_CONF" << EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "h2-in",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "name": "user1",
          "password": "${PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${SERVER_CRT}",
        "key_path": "${SERVER_KEY}"
      },
      "masquerade": "https://www.cloudflare.com"
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

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
echo ""
echo "------------------------------"
echo "  Hysteria2 客户端配置"
echo "------------------------------"
cat << EOF
    {
      "serverip": "${SERVER_IP}",
      "password": "${PASSWORD}",
      "keySHA256": "${SERVER_CRT_PIN}"
    }
EOF