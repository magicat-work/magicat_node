#!/bin/bash
set -e
trap 'echo "删除失败 (第 ${LINENO} 行)"; exit 1' ERR
[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }
umask 077

if [ "$#" -eq 0 ]; then
  echo "用法: bash del_user.sh NAME [NAME ...]"
  echo "  NAME = config.json 里 users[].name (通常是 YYYY-MM-DD)"
  echo "  重名全部删除；不存在的名字自动忽略"
  echo "  列出当前用户: bash del_user.sh -l"
  exit 1
fi

SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF="/etc/sing-box/config.json"
BAK="${SINGBOX_CONF}.bak"
TMP="${SINGBOX_CONF}.new"

command -v jq >/dev/null || apt-get install -y jq >/dev/null

# ---- -l: 只列出，不改动 ----
if [ "$1" = "-l" ]; then
  jq -r '.inbounds[] | select(has("users")) | .tag as $t
         | .users[] | "\($t)\t\(.name)"' "$SINGBOX_CONF"
  exit 0
fi

# ---- 受保护的常驻账号，防手滑 ----
PROTECTED=("magicat_hy2" "magicat_vless")
for A in "$@"; do
  for P in "${PROTECTED[@]}"; do
    if [ "$A" = "$P" ]; then
      echo "保护用户: ${A}"
      exit 1
    fi
  done
done

# ---- 参数数组 -> JSON 数组 ----
NAMES_JSON=$(printf '%s\n' "$@" | jq -Rn '[inputs]')

# ---- 预检: 命中条数 ----
HIT=$(jq --argjson n "$NAMES_JSON" '
  [ .inbounds[] | select(has("users")).users[] | select(.name | IN($n[])) ] | length
' "$SINGBOX_CONF")

if [ "$HIT" -eq 0 ]; then
  echo "无匹配用户"
  exit 0
fi

echo "将删除 ${HIT} 条:"
jq -r --argjson n "$NAMES_JSON" '
  .inbounds[] | select(has("users")) | .tag as $t
  | .users[] | select(.name | IN($n[])) | "  \($t)\t\(.name)"
' "$SINGBOX_CONF"

# ---- 备份并删除 ----
cp -a "$SINGBOX_CONF" "$BAK"
jq --argjson n "$NAMES_JSON" '
  (.inbounds[] | select(has("users")).users) |= map(select(.name | IN($n[]) | not))
' "$SINGBOX_CONF" > "$TMP"

# ---- 应用前校验 (inbound 被删空时会在此报错，配置不会落地) ----
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

echo "完成 (备份: ${BAK})"

# 用法:
# bash del_user.sh YYYY-MM-DD YYYY-MM-DD ...
# curl -Ls https://raw.githubusercontent.com/magicat-work/magicat_node/main/del_user.sh | bash -s -- YYYY-MM-DD YYYY-MM-DD ...
