#!/bin/bash
# sing-box 卸载 / 还原脚本
[ "$(id -u)" -eq 0 ] || { echo "需要 root 权限"; exit 1; }

# 1. 停止并禁用服务 (先停 timer，避免卸载途中被触发)
systemctl disable --now clean-user.timer 2>/dev/null || true
systemctl stop sing-box 2>/dev/null || true
systemctl disable sing-box 2>/dev/null || true

# 2. 删除 systemd 单元文件
rm -f /etc/systemd/system/sing-box.service
rm -f /etc/systemd/system/clean-user.service /etc/systemd/system/clean-user.timer
systemctl daemon-reload
systemctl reset-failed sing-box clean-user.service clean-user.timer 2>/dev/null || true

# 3. 删除二进制 / 脚本
rm -f /usr/local/bin/sing-box
rm -f /usr/local/bin/clean_user.sh

# 4. 安全擦除并删除配置 / 证书目录
if [ -d /etc/sing-box ]; then
    if command -v shred &>/dev/null; then
        find /etc/sing-box -type f -print0 | xargs -0 -r shred -u -z -n 3
    else
        echo "警告: 未找到 shred 命令"
    fi
fi
rm -rf /etc/sing-box

# 5. 删除专用系统用户
id magicat &>/dev/null && userdel magicat 2>/dev/null || true

# 6. 删除 sysctl 优化配置
rm -f /etc/sysctl.d/99-singbox.conf
sysctl --system >/dev/null 2>&1 || true

echo "清理完成 (证书/密钥已安全擦除)"

# 用法
# bash unins.sh
# curl -Ls https://raw.githubusercontent.com/magicat-work/magicat_node/main/unins.sh | bash