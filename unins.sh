#!/bin/bash
# sing-box 卸载 / 还原脚本
[ "$(id -u)" -eq 0 ] || { echo "需要 root"; exit 1; }

# 1. 停止并禁用服务
systemctl stop sing-box 2>/dev/null || true
systemctl disable sing-box 2>/dev/null || true

# 2. 删除 systemd 服务文件
rm -f /etc/systemd/system/sing-box.service
systemctl daemon-reload
systemctl reset-failed sing-box 2>/dev/null || true

# 3. 删除二进制
rm -f /usr/local/bin/sing-box

# 4. 删除配置 / 证书目录
rm -rf /etc/sing-box

# 5. 删除专用系统用户
id magicat &>/dev/null && userdel magicat 2>/dev/null || true

# 6. 还原 sysctl(见下方说明,谨慎)
sed -i '/net.core.rmem_max=33554432/d' /etc/sysctl.conf
sed -i '/net.core.wmem_max=33554432/d' /etc/sysctl.conf
sed -i '/net.core.rmem_default=1048576/d' /etc/sysctl.conf
sed -i '/net.core.wmem_default=1048576/d' /etc/sysctl.conf
sysctl --system >/dev/null 2>&1 || true

echo "清理完成"