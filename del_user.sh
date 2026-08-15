#!/bin/bash

# bash /root/del_user.sh YYYY-MM-DD YYYY-MM-DD
# curl -Ls https://raw.githubusercontent.com/magicat-work/magicat_node/main/del_user.sh | bash -s -- YYYY-MM-DD YYYY-MM-DD

[ "$(id -u)" -eq 0 ] || { echo "无 root 权限"; exit 1; }
set -Ee -o pipefail
trap 'echo "删除失败: 第 ${LINENO} 行 [${BASH_COMMAND}]" >&2' ERR
umask 077

SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF="/etc/sing-box/config.json"
BAK="${SINGBOX_CONF}.bak"
TMP="${SINGBOX_CONF}.new"

# -l: 列出用户
if [ "$1" = "-l" ]; then
  jq -r '.inbounds[] | select(has("users")) | .tag as $t | .users[] | "\($t)\t\(.name)"' "$SINGBOX_CONF"
  exit 0
fi
[ "$#" -ge 1 ] || exit 1

# 记下将删除的用户，为空则不动配置不重启
NAMES_JSON=$(printf '%s\n' "$@" | jq -Rn '[inputs]')
DELETED=$(jq -r --argjson n "$NAMES_JSON" '.inbounds[] | select(has("users")) | .tag as $t | .users[] | select(.name | IN($n[])) | "  \($t)\t\(.name)"' "$SINGBOX_CONF")
[ -n "$DELETED" ] || { echo "无匹配用户"; exit 0; }

# 备份 + 删除
cp -a "$SINGBOX_CONF" "$BAK"
jq --argjson n "$NAMES_JSON" '(.inbounds[] | select(has("users")).users) |= map(select(.name | IN($n[]) | not))' "$SINGBOX_CONF" > "$TMP"

# 落地前校验
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

echo "已删除 (备份: ${BAK}):"
echo "$DELETED"