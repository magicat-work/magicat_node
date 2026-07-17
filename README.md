# magicat_node

---

## 快速搭建 Sing-box 节点

```bash
curl -Ls https://raw.githubusercontent.com/magicat-work/magicat_node/main/install.sh | bash
```

## 卸载部署
```bash
curl -Ls https://raw.githubusercontent.com/magicat-work/magicat_node/main/unins.sh | bash
```
---

## 服务器要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Debian12+ / Ubuntu 24+ |
| 系统架构 | amd64 |
| 最低配置 | 1核1G |
| 登录权限 | root |
| 端口放行 |  UDP/443、SSH(22) |

---

## 用户系统
### 确认 systemd 版本 ≥ 252
```bash
systemctl --version | head -1
```
### 添加用户
```bash
curl -Ls https://raw.githubusercontent.com/magicat-work/magicat_node/main/add_user.sh | bash
```

---

## 联系咨询

| 方式 | 地址 |
|------|------|
| QQ群 | 745961028 |
| 官网 | https://magicat.work/ |

---