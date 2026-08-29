#!/bin/bash
# bash /root/add.sh
# curl -Ls https://raw.githubusercontent.com/magicat-work/magicat_node/main/add.sh | bash
[ "$(id -u)" -eq 0 ] || { echo "无 root 权限"; exit 1; }
set -Ee -o pipefail
trap 'echo "添加失败: 第 ${LINENO} 行 [${BASH_COMMAND}]" >&2' ERR
umask 077
NODES="/etc/magicat/nodes.tsv"
USERS="/etc/magicat/users.tsv"
SUB_DOMAIN="sub.magicat.work"
[ -f "$NODES" ] && [ -f "$USERS" ] || { echo "未部署 hub.sh"; exit 1; }

# 入口: 一个字段走加用户, 五个字段走加节点
exec 3<> /dev/tty
printf '节点: ' >&3
read -r NODE <&3 || true
read -ra F <<< "$NODE" || true
if [ "${#F[@]}" -ne 5 ]; then
  printf '日期: ' >&3
  read -r DATES <&3 || true
  printf 'token: ' >&3
  read -r INPUT <&3 || true
fi
exec 3>&-

# 添加节点
NODE_RE='^[a-z0-9]+ [A-Za-z0-9]{16,64} [0-9]{1,3}(\.[0-9]{1,3}){3} [0-9]{1,5} [0-9a-f]{64}$'
if [ "${#F[@]}" -eq 5 ]; then
  [[ "${F[*]}" =~ $NODE_RE ]] || { echo "节点格式错误"; exit 1; }
  cp -a "$NODES" "${NODES}.bak"
  awk -F'\t' -v n="${F[0]}" 'NF>=5 && $1==n {next} {print}' "$NODES" > "${NODES}.new"
  printf '%s\t%s\t%s\t%s\t%s\n' "${F[@]}" >> "${NODES}.new"
  DUP=$(awk -F'\t' 'NF>=5{if ($2 in s) {print $2; exit} s[$2]}' "${NODES}.new")
  [ -z "$DUP" ] || { echo "密钥重复: ${DUP}"; rm -f "${NODES}.new"; exit 1; }
  chgrp magicat "${NODES}.new"; chmod 640 "${NODES}.new"
  mv "${NODES}.new" "$NODES"
  echo "节点 ${F[0]} 已添加 (备份: ${NODES}.bak)"
  exit 0
fi

# 添加用户
[ "${#F[@]}" -eq 1 ] && [[ "${F[0]}" =~ ^[a-z0-9]+$ ]] || { echo "节点格式错误"; exit 1; }
NODE="${F[0]}"

# 日期: 为空取下月同日, 溢出取下月首日
read -ra NAMES <<< "$DATES" || true
if [ "${#NAMES[@]}" -eq 0 ]; then
  _d=$((10#$(TZ='Asia/Shanghai' date +%d)))
  _m1=$(date -d "$(TZ='Asia/Shanghai' date +%Y-%m-01) +1 month" +%F)
  _a=$(date -d "$_m1 +$((_d-1)) days" +%F)
  _b=$(date -d "$_m1 +1 month" +%F)
  [[ "$_a" < "$_b" ]] && NAMES=("$_a") || NAMES=("$_b")
fi
for N in "${NAMES[@]}"; do
  [ "$(date -d "$N" +%F 2>/dev/null)" = "$N" ] || { echo "日期无效: ${N}"; exit 1; }
done

# token: 为空自动生成, 非空须已存在且与日期等长
read -ra TOKENS <<< "$INPUT" || true
for T in "${TOKENS[@]}"; do
  [[ "$T" =~ ^[A-Za-z0-9]{16,64}$ ]] || { echo "token 格式错误: ${T}"; exit 1; }
done
[ "${#TOKENS[@]}" -eq 0 ] || [ "${#TOKENS[@]}" -eq "${#NAMES[@]}" ] || { echo "数量不齐"; exit 1; }
MISS=$(printf '%s\n' "${TOKENS[@]}" | awk -F'\t' 'NR==FNR{if (NF) t[$0]; next} NF>=3{delete t[$3]} END{for (k in t) {print k; exit}}' - "$USERS")
[ -z "$MISS" ] || { echo "token 不存在: ${MISS}"; exit 1; }
PWS=()
for i in "${!NAMES[@]}"; do
  PWS[$i]="${TOKENS[$i]:-$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)}"
done

# 备份并写入: 只剔除指定 token 的旧行, 生成的 token 无条件追加
BAK="${USERS}.bak"
TMP="${USERS}.new"
cp -a "$USERS" "$BAK"
printf '%s\n' "${TOKENS[@]}" | awk -F'\t' 'NR==FNR{if (NF) d[$0]; next} !(NF>=3 && $3 in d)' - "$USERS" > "$TMP"
for i in "${!NAMES[@]}"; do
  printf '%s\t%s\t%s\n' "$NODE" "${NAMES[$i]}" "${PWS[$i]}"
done >> "$TMP"

# 应用前校验: 全表 token 唯一
DUP=$(awk -F'\t' 'NF>=3{if ($3 in s) {print $3; exit} s[$3]}' "$TMP")
[ -z "$DUP" ] || { echo "token 重复: ${DUP}"; rm -f "$TMP"; exit 1; }
chgrp magicat "$TMP"; chmod 640 "$TMP"
mv "$TMP" "$USERS"

# 输出
echo "# 处理 ${#NAMES[@]} 个用户 (备份: ${BAK})"
for i in "${!NAMES[@]}"; do
  echo "---"
  if [ -n "${TOKENS[$i]:-}" ]; then
    echo "${NAMES[$i]} ${PWS[$i]}"
  else
    echo "${NAMES[$i]}"
    echo "https://${SUB_DOMAIN}/sub/${PWS[$i]}"
  fi
  echo "---"
done
