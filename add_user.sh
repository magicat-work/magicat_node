#!/bin/bash

# bash /root/add_user.sh
# curl -Ls https://raw.githubusercontent.com/magicat-work/magicat_node/main/add_user.sh | bash

[ "$(id -u)" -eq 0 ] || { echo "无 root 权限"; exit 1; }
set -Ee -o pipefail
trap 'echo "添加失败: 第 ${LINENO} 行 [${BASH_COMMAND}]" >&2' ERR
umask 077
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF="/etc/sing-box/config.json"
CLEAN_URL="https://raw.githubusercontent.com/magicat-work/magicat_node/main/clean_user.sh"
CLEAN_BIN="/usr/local/bin/clean_user.sh"

# jq 检查
if ! command -v jq >/dev/null; then
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y jq >/dev/null
fi

# 交互输入
exec 3<> /dev/tty
printf 'user token: ' >&3
read -r USER_TOKENS <&3 || true
TOK_UUIDS=(); TOK_PWS=(); TOK_JSON='['
read -ra TOKENS <<< "$USER_TOKENS" || true
if [ "${#TOKENS[@]}" -gt 0 ]; then
  DUP=$(printf '%s\n' "${TOKENS[@]}" | sort | uniq -d)
  [ -z "$DUP" ] || { echo "token 重复: ${DUP}"; exit 1; }
  for i in "${!TOKENS[@]}"; do
    T="${TOKENS[$i]}"
    [[ "$T" =~ ^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})([A-Za-z0-9]+)$ ]] \
      || { echo "token 格式错误: ${T}"; exit 1; }
    TOK_UUIDS[$i]="${BASH_REMATCH[1]}"; TOK_PWS[$i]="${BASH_REMATCH[2]}"
    TOK_JSON+="{\"u\":\"${TOK_UUIDS[$i]}\",\"p\":\"${TOK_PWS[$i]}\"},"
  done
fi
TOK_JSON="${TOK_JSON%,}]"
printf '日期: ' >&3
read -r DATES <&3 || true
read -ra NAMES <<< "$DATES" || true
if [ "${#NAMES[@]}" -eq 0 ]; then
  _d=$((10#$(TZ='Asia/Shanghai' date +%d)))
  _m1=$(date -d "$(TZ='Asia/Shanghai' date +%Y-%m-01) +1 month" +%F)
  _a=$(date -d "$_m1 +$((_d-1)) days" +%F)
  _b=$(date -d "$_m1 +1 month" +%F)
  [[ "$_a" < "$_b" ]] && NAMES=("$_a") || NAMES=("$_b")
fi
for N in "${NAMES[@]}"; do
  [[ "$N" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "日期格式错误: ${N}"; exit 1; }
  [ "$(date -d "$N" +%F 2>/dev/null)" = "$N" ] || { echo "日期不存在: ${N}"; exit 1; }
done
[ "${#TOKENS[@]}" -eq 0 ] || [ "${#TOKENS[@]}" -eq "${#NAMES[@]}" ] \
  || { echo "token 与 date 不符"; exit 1; }
printf '订阅域名: ' >&3
read -r SUB_DOMAIN <&3 || true
SUB_DOMAIN="${SUB_DOMAIN//[[:space:]]/}"
[ -n "$SUB_DOMAIN" ] || { echo "无输入"; exit 1; }
exec 3>&-

# 用户参数准备
PWS=(); UUIDS=(); HY_JSON='['; VL_JSON='['
for i in "${!NAMES[@]}"; do
  N="${NAMES[$i]}"
  if [ -n "${TOK_UUIDS[$i]:-}" ]; then
    UUIDS[$i]="${TOK_UUIDS[$i]}"; PWS[$i]="${TOK_PWS[$i]}"
  else
    PWS[$i]=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)
    UUIDS[$i]=$("$SINGBOX_BIN" generate uuid)
  fi
  HY_JSON+="{\"name\":\"${N}\",\"password\":\"${PWS[$i]}\"},"
  VL_JSON+="{\"name\":\"${N}\",\"uuid\":\"${UUIDS[$i]}\",\"flow\":\"xtls-rprx-vision\"},"
done
HY_JSON="${HY_JSON%,}]"; VL_JSON="${VL_JSON%,}]"

# 备份并覆盖写入
BAK="${SINGBOX_CONF}.bak"
cp -a "$SINGBOX_CONF" "$BAK"
TMP="${SINGBOX_CONF}.new"
jq --argjson t "$TOK_JSON" --argjson hy "$HY_JSON" --argjson vl "$VL_JSON" \
  'reduce $t[] as $x (.;
       (.inbounds[] | select(.tag=="vless-in") | .users | map(.uuid)     | index($x.u)) as $i
     | (.inbounds[] | select(.tag=="h2-in")    | .users | map(.password) | index($x.p)) as $j
     | if $i != $j then error("token 匹配失败: " + $x.u)
       elif $i == null then .
       else (.inbounds[] | select(.tag=="h2-in").users)    |= del(.[$i])
          | (.inbounds[] | select(.tag=="vless-in").users) |= del(.[$i])
       end)
   | (.inbounds[] | select(.tag=="h2-in").users)    += $hy
   | (.inbounds[] | select(.tag=="vless-in").users) += $vl' \
  "$SINGBOX_CONF" > "$TMP"

# 应用前校验语法
"$SINGBOX_BIN" check -c "$TMP"
chown magicat "$TMP"; chmod 600 "$TMP"
mv "$TMP" "$SINGBOX_CONF"

# 重启失败回滚
if ! systemctl restart sing-box; then
  echo "重启失败，回滚到 $BAK"
  cp -a "$BAK" "$SINGBOX_CONF"
  chown magicat "$SINGBOX_CONF"; chmod 600 "$SINGBOX_CONF"
  systemctl restart sing-box
  exit 1
fi

# 重启成功备份配置
cp "$SINGBOX_CONF" /root/config.json

# 部署清理脚本
_clean_tmp="${CLEAN_BIN}.new"
curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$_clean_tmp" "$CLEAN_URL"
chmod 755 "$_clean_tmp"
mv -f "$_clean_tmp" "$CLEAN_BIN"

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
AccuracySec=5min
[Install]
WantedBy=timers.target
EOF

# 再启动定时清理
systemctl daemon-reload
systemctl enable clean-user.timer >/dev/null
systemctl restart clean-user.timer

# 输出订阅
[ "${#TOKENS[@]}" -gt 0 ] && ACTION="续期" || ACTION="新增"
echo "# ${ACTION} ${#NAMES[@]} 个用户 (备份: ${BAK})"
for i in "${!NAMES[@]}"; do
  echo "---"
  echo "${NAMES[$i]}"
  echo "https://${SUB_DOMAIN}/sub/${UUIDS[$i]}${PWS[$i]}"
  echo "---"
done