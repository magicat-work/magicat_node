#!/bin/bash
set -e
trap 'echo "添加失败 (第 ${LINENO} 行)"; exit 1' ERR
[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }
umask 077

# 不带参数时 = 中国时区「下个月的今天」，格式 YYYY-MM-DD
# 下月无该日时 (如 1-31 → 2月) 取下下月 1 号：即 min(下月今天, 下下月1号)
if [ "$#" -eq 0 ]; then
  _d=$((10#$(TZ='Asia/Shanghai' date +%d)))
  _m1=$(date -d "$(TZ='Asia/Shanghai' date +%Y-%m-01) +1 month" +%F)  # 下月1号
  _a=$(date -d "$_m1 +$((_d-1)) days" +%F)                            # 下月今天(溢出自动顺延)
  _b=$(date -d "$_m1 +1 month" +%F)                                   # 下下月1号
  [[ "$_a" < "$_b" ]] && NAMES=("$_a") || NAMES=("$_b")
else
  NAMES=("$@")
fi

# 校验: 每个都必须是严格 YYYY-MM-DD 格式，且为真实存在的日期
for N in "${NAMES[@]}"; do
  [[ "$N" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
    || { echo "用户名格式错误: ${N}"; exit 1; }
  [ "$(date -d "$N" +%F 2>/dev/null)" = "$N" ] \
    || { echo "日期不存在: ${N}"; exit 1; }
done

SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF="/etc/sing-box/config.json"
SERVER_CRT="/etc/sing-box/server.crt"

command -v jq >/dev/null || apt-get install -y jq >/dev/null

# ---- 从现有配置读取服务器级共享参数 ----
PORT=$(jq -r '.inbounds[] | select(.tag=="h2-in") | .listen_port' "$SINGBOX_CONF")
REALITY_SNI=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .tls.server_name' "$SINGBOX_CONF")
SHORT_ID=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .tls.reality.short_id[0]' "$SINGBOX_CONF")
REALITY_PRIVATE=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .tls.reality.private_key' "$SINGBOX_CONF")

# 公网 IP：配置里没存，重新获取（失败则回退到证书 SAN）
SERVER_IP=$(curl -fsS --proto '=https' --tlsv1.2 --max-time 10 https://api.ipify.org)

# HY2 证书指纹（与部署脚本算法一致）
CERT_PIN=$(openssl x509 -in "$SERVER_CRT" -outform der | openssl dgst -sha256 -r | cut -d' ' -f1)

# ---- 从 REALITY 私钥反推公钥 (pbk)，X25519 ----
pad(){ local s="$1"; while [ $(( ${#s} % 4 )) -ne 0 ]; do s="${s}="; done; printf '%s' "$s"; }
REALITY_PUBLIC=$(
  { printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20'
    pad "$REALITY_PRIVATE" | basenc --base64url -d; } \
  | openssl pkey -inform DER -pubout -outform DER \
  | tail -c 32 | basenc --base64url | tr -d '='
)

# ---- 逐个生成独立凭据，汇总成两个 JSON 数组 ----
# 用下标数组与 NAMES 一一对应（允许重名，故不能用名字做键）
PWS=(); UUIDS=()
HY_JSON='[]'; VL_JSON='[]'
for i in "${!NAMES[@]}"; do
  N="${NAMES[$i]}"
  PWS[$i]=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  UUIDS[$i]=$("$SINGBOX_BIN" generate uuid)
  HY_JSON=$(printf '%s' "$HY_JSON" | jq --arg n "$N" --arg p "${PWS[$i]}" \
    '. + [{"name":$n,"password":$p}]')
  VL_JSON=$(printf '%s' "$VL_JSON" | jq --arg n "$N" --arg u "${UUIDS[$i]}" \
    '. + [{"name":$n,"uuid":$u,"flow":"xtls-rprx-vision"}]')
done

# ---- 备份并写入 (固定文件名，每次覆盖，只保留上一次配置) ----
BAK="${SINGBOX_CONF}.bak"
cp -a "$SINGBOX_CONF" "$BAK"

TMP="${SINGBOX_CONF}.new"
jq --argjson hy "$HY_JSON" --argjson vl "$VL_JSON" \
  '(.inbounds[] | select(.tag=="h2-in").users)   += $hy
 | (.inbounds[] | select(.tag=="vless-in").users) += $vl' \
  "$SINGBOX_CONF" > "$TMP"

# 应用前校验语法
"$SINGBOX_BIN" check -c "$TMP"

mv "$TMP" "$SINGBOX_CONF"
chown magicat "$SINGBOX_CONF"
chmod 600 "$SINGBOX_CONF"

# ---- 重启，失败自动回滚 ----
if ! systemctl restart sing-box; then
  echo "重启失败，回滚到 $BAK"
  cp -a "$BAK" "$SINGBOX_CONF"
  chown magicat "$SINGBOX_CONF"; chmod 600 "$SINGBOX_CONF"
  systemctl restart sing-box
  exit 1
fi

# ---- 逐个输出新用户的客户端链接 ----
echo "------"
echo "# 新增 ${#NAMES[@]} 个用户   (备份: ${BAK})"
for i in "${!NAMES[@]}"; do
  N="${NAMES[$i]}"
  UUID="${UUIDS[$i]}"
  PASSWORD="${PWS[$i]}"
  HY2_URI="hysteria2://${PASSWORD}@${SERVER_IP}:${PORT}/?sni=cloudflare.com&pinSHA256=${CERT_PIN}#${N}_HY2"
  VLESS_URI="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp#${N}_VLESS"
  echo "------"
  echo "# ${N}"
  echo "------"
  echo "${HY2_URI}"
  echo "---"
  echo "${VLESS_URI}"
done
echo "------"

# 运行 bash add_user.sh YYYY-MM-DD YYYY-MM-DD ...
# curl -Ls https://raw.githubusercontent.com/magicat-work/magicat_node/main/add_user.sh | bash -s -- YYYY-MM-DD YYYY-MM-DD ...

# ================= 过期用户清理服务 =================
# 用户名即到期日 (YYYY-MM-DD)，每天北京时间 06:00 清理过期用户
# 非日期名字 (magicat_hy2 / magicat_vless) 不受影响
CLEAN_URL="https://raw.githubusercontent.com/magicat-work/magicat_node/main/clean_user.sh"
CLEAN_BIN="/usr/local/bin/clean_user.sh"

# jq
command -v jq >/dev/null || { apt-get update -qq >/dev/null; apt-get install -y jq >/dev/null; }

curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$CLEAN_BIN" "$CLEAN_URL"
chmod 755 "$CLEAN_BIN"

cat > /etc/systemd/system/clean-user.service << 'EOF'
[Unit]
Description=Remove expired sing-box users
After=network.target
ConditionPathExists=/etc/sing-box/config.json
[Service]
Type=oneshot
ExecStart=/usr/local/bin/clean_user.sh
EOF

cat > /etc/systemd/system/clean-user.timer << 'EOF'
[Unit]
Description=Daily expired sing-box user cleanup (06:00 Asia/Shanghai)
[Timer]
OnCalendar=*-*-* 06:00:00 Asia/Shanghai
Persistent=true
AccuracySec=10min
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable clean-user.timer >/dev/null 2>&1
systemctl restart clean-user.timer
