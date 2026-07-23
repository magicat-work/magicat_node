#!/bin/bash
set -e
trap 'echo "删除失败 (第 ${LINENO} 行)"; exit 1' ERR
[ "$(id -u)" -eq 0 ] || { echo "无 root 权限"; exit 1; }
umask 077

SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF="/etc/sing-box/config.json"
BAK="${SINGBOX_CONF}.bak"
TMP="${SINGBOX_CONF}.new"
PROTECTED=("magicat_hy2" "magicat_vless")

# -l: 列出用户
if [ "$1" = "-l" ]; then
  jq -r '.inbounds[]|select(has("users"))|.tag as $t|.users[]|"\($t)\t\(.name)"' "$SINGBOX_CONF"
  exit 0
fi

[ "$#" -ge 1 ] || exit 1

# 保护常驻账号
for A in "$@"; do
  for P in "${PROTECTED[@]}"; do
    [ "$A" = "$P" ] && { echo "保护用户: ${A}"; exit 1; }
  done
done

NAMES_JSON=$(printf '%s\n' "$@" | jq -Rn '[inputs]')

# 命中预检：无匹配则不重启服务
HIT=$(jq --argjson n "$NAMES_JSON" '[.inbounds[]|select(has("users")).users[]|select(.name|IN($n[]))]|length' "$SINGBOX_CONF")
[ "$HIT" -eq 0 ] && { echo "无匹配用户"; exit 0; }

# 记下将删除的用户（删除后原配置就没了，得先抓）
DELETED=$(jq -r --argjson n "$NAMES_JSON" '.inbounds[]|select(has("users"))|.tag as $t|.users[]|select(.name|IN($n[]))|"  \($t)\t\(.name)"' "$SINGBOX_CONF")

# 备份 + 删除
cp -a "$SINGBOX_CONF" "$BAK"
jq --argjson n "$NAMES_JSON" '(.inbounds[]|select(has("users")).users) |= map(select(.name|IN($n[])|not))' "$SINGBOX_CONF" > "$TMP"

# 落地前校验
"$SINGBOX_BIN" check -c "$TMP"

mv "$TMP" "$SINGBOX_CONF"
chown magicat "$SINGBOX_CONF"; chmod 600 "$SINGBOX_CONF"

# 重启，失败回滚
if ! systemctl restart sing-box; then
  cp -a "$BAK" "$SINGBOX_CONF"; chown magicat "$SINGBOX_CONF"; chmod 600 "$SINGBOX_CONF"
  systemctl restart sing-box
  echo "重启失败，已回滚"; exit 1
fi

echo "已删除 ${HIT} 条 (备份: ${BAK}):"
echo "$DELETED"

# 用法:
# bash del_user.sh YYYY-MM-DD YYYY-MM-DD
# curl -Ls https://raw.githubusercontent.com/magicat-work/magicat_node/main/del_user.sh | bash -s -- YYYY-MM-DD YYYY-MM-DD