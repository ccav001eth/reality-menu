# 梯哥 Reality 管理菜单

需要 **root**。一键安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccav001eth/reality-menu/main/reality-menu.sh)
```

jsDelivr 备用：

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/ccav001eth/reality-menu@main/reality-menu.sh)
```

安装、更新与卸载 Xray 时调用 [XTLS 官方 Xray-install 脚本](https://github.com/XTLS/Xray-install)。本菜单在此基础上写入 VLESS + Reality 配置，并生成导入链接。

## 菜单

1. 安装 / 重装（生成新密钥与导入链接；已有配置时需确认）
2. 查看导入链接和二维码
3. 查看运行状态
4. 查看最近日志
5. 重启服务
6. 更新 Xray（配置不变）
7. 卸载（确认后删除 Xray 与链接文件）
