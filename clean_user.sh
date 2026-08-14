#!/bin/bash

# 日志 TZ='Asia/Shanghai' journalctl -u clean-user.service --no-pager -o short-full

set -Ee -o pipefail
trap 'echo "清理失败: 第 ${LINENO} 行 [${BASH_COMMAND}]" >&2' ERR
umask 077
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF="/etc/sing-box/config.json"
BAK="${SINGBOX_CONF}.bak"
TMP="${SINGBOX_CONF}.new"

# 用户名即到期日，仅处理 YYYY-MM-DD
DATE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
TODAY=$(TZ='Asia/Shanghai' date +%F)

# 无过期用户直接退出，避免无谓重启
HAS=$(jq --arg t "$TODAY" --arg re "$DATE_RE" 'any(.inbounds[] | select(has("users")).users[].name; test($re) and . < $t)' "$SINGBOX_CONF")
[ "$HAS" = "true" ] || exit 0

# 备份并删除
cp -a "$SINGBOX_CONF" "$BAK"
jq --arg t "$TODAY" --arg re "$DATE_RE" '(.inbounds[] | select(has("users")).users) |= map(select((.name | test($re) | not) or (.name >= $t)))' "$SINGBOX_CONF" > "$TMP"

# 应用前校验
"$SINGBOX_BIN" check -c "$TMP"
chown magicat "$TMP"; chmod 600 "$TMP"
mv "$TMP" "$SINGBOX_CONF"

# 重启失败回滚
if ! systemctl restart sing-box; then
  echo "重启失败，回滚到 ${BAK}"
  cp -a "$BAK" "$SINGBOX_CONF"
  chown magicat "$SINGBOX_CONF"; chmod 600 "$SINGBOX_CONF"
  systemctl restart sing-box
  exit 1
fi
cp "$SINGBOX_CONF" /root/config.json