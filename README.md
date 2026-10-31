# reality-menu

VLESS + Reality 一键管理菜单（基于 XTLS 官方安装脚本），带**通用订阅**。

## 一条命令，一条订阅

在 VPS 上用 root 运行（全自动，默认 443 端口、伪装域名 www.microsoft.com）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccav001eth/reality-menu/main/reality-menu.sh) install
```

装完会直接显示 **通用订阅链接 + 二维码**（另附单节点 vless 链接备用）。把这条订阅链接导入
v2rayN / v2rayNG / Shadowrocket（小火箭）/ Clash Verge / OpenClash / NekoBox / Hiddify 即可使用，客户端会自动识别格式。

自定义端口或伪装域名：`PORT=8443 SNI=www.microsoft.com bash <(curl -fsSL .../reality-menu.sh) install`

不带 `install` 运行则进入交互菜单：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccav001eth/reality-menu/main/reality-menu.sh)
```

## 菜单

| 选项 | 功能 |
|---|---|
| 1 | 安装 / 重装（自动开启订阅，生成新链接） |
| 2 | 查看订阅链接、单节点链接和二维码 |
| 3 | 查看运行状态 |
| 4 | 查看最近日志 |
| 5 | 重启服务 |
| 6 | 更新 Xray（配置不变） |
| 7 | 卸载（含订阅服务） |
| 8 | 开启 / 查看订阅（通用订阅链接） |
| 9 | 重置订阅地址（旧地址失效） |
| 10 | 关闭订阅 |

## 通用订阅

安装时自动开启（之后也可用 8 查看/开启），会生成一条 `http://服务器IP:随机端口/随机32位路径` 的订阅地址和二维码，各客户端填同一条即可：

- **Clash / Clash Verge / OpenClash / mihomo / Stash**：自动返回 Clash Meta 配置（含 reality-opts、手动选择 + 自动测速分组、局域网和国内直连）。OpenClash 需使用 Meta 内核。
- **v2rayN / v2rayNG / Shadowrocket（小火箭）/ NekoBox / Hiddify 及其他**：返回 Base64 编码的 `vless://` 链接。
- 识别不准时可在地址后加 `?target=clash` 或 `?target=v2ray` 强制格式。

订阅内容在每次请求时从 `/usr/local/etc/xray/config.json` 实时生成，新增用户/UUID 后客户端点更新即可。已用旧版脚本安装的服务器也可直接选 8，不会重新生成密钥（公钥从 `/root/reality-link.txt` 读取）。

说明：
- 订阅服务是一个 python3 小服务（systemd: `reality-sub`），无需域名，走 HTTP 明文。
- 订阅地址等于节点密码，不要公开；泄露后用 9 重置。
- ufw/firewalld 开启时会自动放行端口；云服务商安全组需自行放行。
