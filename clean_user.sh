#!/bin/bash
set -e
trap 'echo "清理失败 (第 ${LINENO} 行)"; exit 1' ERR
[ "$(id -u)" -eq 0 ] || { echo "无 root 权限"; exit 1; }
umask 077

SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF="/etc/sing-box/config.json"
BAK="${SINGBOX_CONF}.bak"
TMP="${SINGBOX_CONF}.new"

# 仅处理 YYYY-MM-DD 格式的用户名即到期日
DATE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
TODAY=$(TZ='Asia/Shanghai' date +%F)

command -v jq >/dev/null || apt-get install -y jq >/dev/null

# ---- 先列出将被清理的用户 ----
EXPIRED=$(jq -r --arg t "$TODAY" --arg re "$DATE_RE" '
  [ .inbounds[] | select(has("users")).users[].name ]
  | map(select(test($re) and . < $t)) | unique | .[]' "$SINGBOX_CONF")

# ---- 没有过期用户就直接退出 ----
if [ -z "$EXPIRED" ]; then
  echo "无过期用户"
  exit 0
fi
echo "清理过期用户: $(echo "$EXPIRED" | tr '\n' ' ')"

# ---- 备份并删除 ----
cp -a "$SINGBOX_CONF" "$BAK"
jq --arg t "$TODAY" --arg re "$DATE_RE" '
  (.inbounds[] | select(has("users")).users) |= map(
    select( (.name | test($re) | not) or (.name >= $t) )
  )' "$SINGBOX_CONF" > "$TMP"

# 应用前校验
"$SINGBOX_BIN" check -c "$TMP"

mv "$TMP" "$SINGBOX_CONF"
chown magicat "$SINGBOX_CONF"
chmod 600 "$SINGBOX_CONF"

# ---- 重启，失败回滚 ----
if ! systemctl restart sing-box; then
  echo "重启失败，回滚到 ${BAK}"
  cp -a "$BAK" "$SINGBOX_CONF"
  chown magicat "$SINGBOX_CONF"; chmod 600 "$SINGBOX_CONF"
  systemctl restart sing-box
  exit 1
fi

# 日志 TZ='Asia/Shanghai' journalctl -u clean-user.service --no-pager -o short-full