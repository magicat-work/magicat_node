#!/bin/bash
# bash /root/magicat.sh
# curl -Ls https://raw.githubusercontent.com/magicat-work/magicat_node/main/magicat.sh | bash

[ "$(id -u)" -eq 0 ] || { echo "无 root 权限"; exit 1; }
set -Ee -o pipefail
trap 'echo "失败: 第 ${LINENO} 行 [${BASH_COMMAND}]" >&2' ERR
umask 077

# 参数
DOWNLOAD_URL="https://github.com/magicat-work/magicat_node/releases/download/amd64/sing-box"
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF="/etc/sing-box/config.json"
SERVER_KEY="/etc/sing-box/server.key"
SERVER_CRT="/etc/sing-box/server.crt"
PORT=443
SERVER_IP=$(curl -fsS --proto '=https' --tlsv1.2 --max-time 10 https://api.ipify.org)

do_install() {
id magicat &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin magicat
MODE="${1:-}"
command -v jq >/dev/null || {
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y jq >/dev/null || { echo "jq 安装失败"; exit 1; }
}

# 更新模式：取出并校验现有 users
if [ "$MODE" = "update" ]; then
  HY_USERS=$(jq -c '(.inbounds[] | select(.tag=="h2-in").users) // empty'    "$SINGBOX_CONF")
  VL_USERS=$(jq -c '(.inbounds[] | select(.tag=="vless-in").users) // empty' "$SINGBOX_CONF")
  [ -n "$HY_USERS" ] && [ -n "$VL_USERS" ] || { echo "users 读取失败"; exit 1; }
  jq -e -n --argjson hy "$HY_USERS" --argjson vl "$VL_USERS" '($hy | length) > 0 and ($hy | map(.name)) == ($vl | map(.name)) and ($hy | all(.password? // "" | length > 0)) and ($vl | all(.uuid? // "" | length > 0))' >/dev/null || {
      echo "${SINGBOX_CONF} 用户信息损坏"
      echo "h2-in   : $(jq -c 'map(.name)' <<<"$HY_USERS")"
      echo "vless-in: $(jq -c 'map(.name)' <<<"$VL_USERS")"
      exit 1
    }
fi

# 系统优化
cat > /etc/sysctl.d/99-singbox.conf << 'EOF'
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 131072 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.tcp_slow_start_after_idle=0
EOF
sysctl --system >/dev/null

# 伪装页面
mkdir -p /var/www/html
cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>It works!</title></head>
<body><h1>It works!</h1><p>This is the default web page for this server.</p>
<p>The web server software is running but no content has been added, yet.</p>
</body></html>
EOF
chmod 755 /var/www /var/www/html
chmod 644 /var/www/html/index.html

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

# 配置参数
PASSWORD=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)
UUID=$("${SINGBOX_BIN}.new" generate uuid)
REALITY_SNI="www.cloudflare.com"
REALITY_KEYS=$("${SINGBOX_BIN}.new" generate reality-keypair)
REALITY_PRIVATE=$(awk '/PrivateKey/{print $2}' <<<"$REALITY_KEYS")
REALITY_PUBLIC=$(awk '/PublicKey/{print $2}' <<<"$REALITY_KEYS")
SHORT_ID=$(openssl rand -hex 4)

# sing-box 配置
cat > "${SINGBOX_CONF}.new" << EOF
{
  "log": {"disabled": true},
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "h2-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [{"name": "magicat", "password": "${PASSWORD}"}],
      "ignore_client_bandwidth": true,
      "tls": {
        "enabled": true,
        "certificate_path": "${SERVER_CRT}",
        "key_path": "${SERVER_KEY}"
      },
      "masquerade": {
        "type": "file",
        "directory": "/var/www/html"
      }
    },
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [{"name": "magicat", "uuid": "${UUID}", "flow": "xtls-rprx-vision"}],
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
    { "type": "direct", "tag": "direct" }
  ],
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "secret": "magicat9090"
    }
  }
}
EOF

# 更新模式: 用旧 users 整体覆盖两个入站
if [ "$MODE" = "update" ]; then
  jq --argjson hy "$HY_USERS" --argjson vl "$VL_USERS" '(.inbounds[] | select(.tag=="h2-in").users) = $hy | (.inbounds[] | select(.tag=="vless-in").users) = $vl' "${SINGBOX_CONF}.new" > "${SINGBOX_CONF}.tmp"
  mv "${SINGBOX_CONF}.tmp" "${SINGBOX_CONF}.new"
fi

# 校验通过才落地，不通过则任何旧文件都不动
jq --arg c "${SERVER_CRT}.new" --arg k "${SERVER_KEY}.new" '(.inbounds[]|select(.tag=="h2-in").tls) |= (.certificate_path=$c|.key_path=$k)' "${SINGBOX_CONF}.new" | "${SINGBOX_BIN}.new" check -c /dev/stdin
chown magicat "${SERVER_KEY}.new" "${SERVER_CRT}.new" "${SINGBOX_CONF}.new"
mv "${SERVER_KEY}.new" "$SERVER_KEY"; mv "${SERVER_CRT}.new" "$SERVER_CRT"
mv "${SINGBOX_BIN}.new" "$SINGBOX_BIN"
mv "${SINGBOX_CONF}.new" "$SINGBOX_CONF"
chown magicat /etc/sing-box
chmod 700 /etc/sing-box

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
systemctl enable sing-box >/dev/null
systemctl restart sing-box

# 备份配置
cp "$SINGBOX_CONF" /root/config.json
if [ "$MODE" = "update" ]; then echo "更新完成: sing-box ${SB_VER}"; else echo "安装完成"; fi

# magicat 的直连配置
CERT_PIN=$(openssl x509 -in "$SERVER_CRT" -outform der | openssl dgst -sha256 -r | cut -d' ' -f1)
MG_PASS=$(jq -r '.inbounds[] | select(.tag=="h2-in").users[] | select(.name=="magicat").password' "$SINGBOX_CONF")
MG_UUID=$(jq -r '.inbounds[] | select(.tag=="vless-in").users[] | select(.name=="magicat").uuid' "$SINGBOX_CONF")
echo "---"
echo "hysteria2://${MG_PASS}@${SERVER_IP}:${PORT}/?pinSHA256=${CERT_PIN}#magicat_HY2"
echo "vless://${MG_UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp#magicat_VLESS"
echo "---"
}

# 卸载部署
do_uninstall() {
systemctl disable --now clean-user.timer 2>/dev/null || true
systemctl stop sing-box 2>/dev/null || true
systemctl disable sing-box 2>/dev/null || true
rm -f /etc/systemd/system/sing-box.service
rm -f /etc/systemd/system/clean-user.service /etc/systemd/system/clean-user.timer
systemctl daemon-reload
systemctl reset-failed sing-box clean-user.service clean-user.timer 2>/dev/null || true
rm -f /usr/local/bin/sing-box /usr/local/bin/sing-box.new /usr/local/bin/clean_user.sh
rm -rf /etc/sing-box
rm -rf /var/www/html
rmdir /var/www 2>/dev/null || true
id magicat &>/dev/null && userdel magicat 2>/dev/null || true
rm -f /etc/sysctl.d/99-singbox.conf
sysctl --system >/dev/null 2>&1 || true
echo "清理完成"
}

# 入口
exec 3<> /dev/tty
cat >&3 << 'EOF'
[1] 安装
[2] 卸载
[3] 更新
EOF
printf '请选择: ' >&3
read -r CHOICE <&3
exec 3>&-
case "$CHOICE" in
  1) [ ! -s "$SINGBOX_CONF" ] || { echo "${SINGBOX_CONF} 已存在"; exit 1; }; do_install ;;
  2) do_uninstall ;;
  3) [ -s "$SINGBOX_CONF" ] || { echo "未检测到 ${SINGBOX_CONF}"; exit 1; }; do_install update ;;
  *) echo "无效输入: '${CHOICE}'"; exit 1 ;;
esac