#!/bin/bash
# bash /root/magicat.sh
# curl -Ls https://raw.githubusercontent.com/magicat-work/magicat_node/main/magicat.sh | bash

[ "$(id -u)" -eq 0 ] || { echo "无 root 权限"; exit 1; }

# 参数
DOWNLOAD_URL="https://github.com/magicat-work/magicat_node/releases/download/amd64/sing-box"
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF="/etc/sing-box/config.json"
SERVER_KEY="/etc/sing-box/server.key"
SERVER_CRT="/etc/sing-box/server.crt"
REALITY_SNI="www.cloudflare.com"
PORT=443

do_install() {
set -Ee -o pipefail
trap 'echo "部署失败 (第 ${LINENO} 行)"; exit 1' ERR
umask 077
SERVER_IP=$(curl -fsS --proto '=https' --tlsv1.2 --max-time 10 https://api.ipify.org)
PASSWORD=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)

# 重建模式
REBUILD="${1:-}"
if [ -n "$REBUILD" ]; then
  [ -s "$SINGBOX_CONF" ] || { echo "未检测到 ${SINGBOX_CONF}，无法重建"; exit 1; }
  command -v jq >/dev/null || {
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y jq >/dev/null || { echo "jq 安装失败"; exit 1; }
  }
  HY_USERS=$(jq -c '(.inbounds[] | select(.tag=="h2-in").users) // empty'    "$SINGBOX_CONF")
  VL_USERS=$(jq -c '(.inbounds[] | select(.tag=="vless-in").users) // empty' "$SINGBOX_CONF")
  [ -n "$HY_USERS" ] && [ -n "$VL_USERS" ] || { echo "users 读取失败，已中止"; exit 1; }

  # 两个入站必须完全对应: 名字序列逐位相同、非空、凭据字段齐全
  jq -e -n --argjson hy "$HY_USERS" --argjson vl "$VL_USERS" 'def norm: map(.name | if . == "magicat_hy2" or . == "magicat_vless" then "magicat" else . end); ($hy | length) > 0 and ($hy | norm) == ($vl | norm) and ($hy | all(.password? // "" | length > 0)) and ($vl | all(.uuid? // "" | length > 0))' >/dev/null || {
      echo "users 不一致或字段缺失"
      echo "h2-in   : $(jq -c 'map(.name)' <<<"$HY_USERS")"
      echo "vless-in: $(jq -c 'map(.name)' <<<"$VL_USERS")"
      exit 1
    }

  cp -a "$SINGBOX_CONF" /root/config.json.bak
fi

# 专用系统用户
id magicat &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin magicat

# 系统优化 (BBR + UDP 缓冲)
# 手动执行
# sysctl --system
# tc qdisc replace dev ens6 root fq
cat > /etc/sysctl.d/99-singbox.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 131072 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.tcp_slow_start_after_idle=0
EOF
sysctl --system

# default_qdisc 仅对新建设备生效,现有网卡需手动切换
NIC=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$NIC" ] && { tc qdisc replace dev "$NIC" root fq 2>/dev/null || true; }

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
systemctl stop sing-box 2>/dev/null || true
curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$SINGBOX_BIN" "$DOWNLOAD_URL"
chmod 755 "$SINGBOX_BIN"

# 自签名证书
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout "$SERVER_KEY" -out "$SERVER_CRT" -days 5475 -extensions ext \
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

chown magicat "$SERVER_KEY" "$SERVER_CRT"
chmod 600 "$SERVER_KEY" "$SERVER_CRT"
CERT_PIN=$(openssl x509 -in "$SERVER_CRT" -outform der | openssl dgst -sha256 -r | cut -d' ' -f1)
HY2_URI="hysteria2://${PASSWORD}@${SERVER_IP}:${PORT}/?pinSHA256=${CERT_PIN}#magicat_HY2"

# VLESS + REALITY 参数
UUID=$("$SINGBOX_BIN" generate uuid)
REALITY_KEYS=$("$SINGBOX_BIN" generate reality-keypair)
REALITY_PRIVATE=$(echo "$REALITY_KEYS" | awk '/PrivateKey/{print $2}')
REALITY_PUBLIC=$(echo "$REALITY_KEYS" | awk '/PublicKey/{print $2}')
SHORT_ID=$(openssl rand -hex 4)
VLESS_URI="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp#magicat_VLESS"

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
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

# 重建模式: 用旧 users 整体覆盖两个入站
if [ -n "$REBUILD" ]; then
  jq --argjson hy "$HY_USERS" --argjson vl "$VL_USERS" '(.inbounds[] | select(.tag=="h2-in").users) = $hy | (.inbounds[] | select(.tag=="vless-in").users) = $vl' "$SINGBOX_CONF" > "${SINGBOX_CONF}.new"
  mv "${SINGBOX_CONF}.new" "$SINGBOX_CONF"
  "$SINGBOX_BIN" check -c "$SINGBOX_CONF"
fi

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

# 客户端信息
if [ -n "$REBUILD" ]; then
  PAIRS=$(jq -r -n --argjson hy "$HY_USERS" --argjson vl "$VL_USERS" '[$hy, $vl] | transpose[] | [.[0].name, .[0].password, .[1].name, .[1].uuid] | @tsv')
  while IFS=$'\t' read -r NH P NV U; do
    echo "---"
    echo "hysteria2://${P}@${SERVER_IP}:${PORT}/?pinSHA256=${CERT_PIN}#${NH}_HY2"
    echo "vless://${U}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp#${NV}_VLESS"
    echo "---"
  done <<< "$PAIRS"
else
  echo "---"
  echo "${HY2_URI}"
  echo "${VLESS_URI}"
  echo "---"
fi
}

do_uninstall() {
# 停止并禁用服务
systemctl disable --now clean-user.timer 2>/dev/null || true
systemctl stop sing-box 2>/dev/null || true
systemctl disable sing-box 2>/dev/null || true

# 删除 systemd 单元文件
rm -f /etc/systemd/system/sing-box.service
rm -f /etc/systemd/system/clean-user.service /etc/systemd/system/clean-user.timer
systemctl daemon-reload
systemctl reset-failed sing-box clean-user.service clean-user.timer 2>/dev/null || true

# 删除二进制 / 脚本
rm -f /usr/local/bin/sing-box /usr/local/bin/sing-box.bak
rm -f /usr/local/bin/clean_user.sh

# 删除目录
rm -rf /etc/sing-box

# 删除伪装页面目录
rm -rf /var/www/html
rmdir /var/www 2>/dev/null || true

# 删除专用系统用户
id magicat &>/dev/null && userdel magicat 2>/dev/null || true

# 删除 sysctl 优化配置
rm -f /etc/sysctl.d/99-singbox.conf
sysctl --system >/dev/null 2>&1 || true
NIC=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$NIC" ] && { tc qdisc replace dev "$NIC" root fq_codel 2>/dev/null || true; }
echo "清理完成"
}

do_update() {
set -Ee -o pipefail
trap 'echo "更新失败"; exit 1' ERR
umask 077

# 1. 无内核直接退出
[ -x "$SINGBOX_BIN" ] || { echo "未检测到 ${SINGBOX_BIN}"; exit 1; }

# 2. 备份原内核，拉取官方最新版覆盖替换 (固定 linux-amd64)
SB_REPO="SagerNet/sing-box"
SB_TAG=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --proto '=https' --tlsv1.2 --max-time 15 "https://github.com/${SB_REPO}/releases/latest" | sed 's#.*/tag/##')
SB_VER="${SB_TAG#v}"
CUR_VER=$("$SINGBOX_BIN" version 2>/dev/null | awk '/^sing-box version/{print $3}') || true
[ "$CUR_VER" = "$SB_VER" ] && { echo "已是最新: sing-box ${SB_VER}"; return 0; }
SB_TMP=$(mktemp -d)
trap 'rm -rf "$SB_TMP"' EXIT
curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "${SB_TMP}/sb.tar.gz" \
  "https://github.com/${SB_REPO}/releases/download/${SB_TAG}/sing-box-${SB_VER}-linux-amd64.tar.gz"
tar -xzf "${SB_TMP}/sb.tar.gz" -C "$SB_TMP"
systemctl stop sing-box 2>/dev/null || true
cp -a "$SINGBOX_BIN" "${SINGBOX_BIN}.bak"
install -m 755 "${SB_TMP}/sing-box-${SB_VER}-linux-amd64/sing-box" "$SINGBOX_BIN"

# 3. 校验通过则启动，否则回滚
if "$SINGBOX_BIN" check -c "$SINGBOX_CONF"; then
  rm -f "${SINGBOX_BIN}.bak"
  systemctl start sing-box
  echo "更新至 sing-box ${SB_VER}"
else
  mv -f "${SINGBOX_BIN}.bak" "$SINGBOX_BIN"
  systemctl start sing-box 2>/dev/null || true
  echo "更新失败，已回滚"
  exit 1
fi
}

# 入口
exec 3<> /dev/tty || { echo "无控制终端" >&2; exit 1; }
cat >&3 << 'EOF'
[1] 安装
[2] 卸载
[3] 更新
[4] 重建
EOF
printf '请选择: ' >&3
read -r CHOICE <&3
exec 3>&-

case "$CHOICE" in
  1) do_install ;;
  2) do_uninstall ;;
  3) do_update ;;
  4) do_install rebuild ;;
  *) echo "无效输入: '${CHOICE}'"; exit 1 ;;
esac