# reality-menu

VLESS + Reality 一键管理菜单（基于 XTLS 官方安装脚本），带**通用订阅**。

## 一条命令，一条订阅

在 VPS 上用 root 运行（全自动，默认 443 端口、伪装域名 www.microsoft.com）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccav001eth/reality-menu/main/reality-menu.sh) install
```

装完会直接显示 **通用订阅链接 + 二维码**（另附单节点 vless 链接备用）。把这条订阅链接导入
v2rayN / v2rayNG / Shadowrocket（小火箭）/ Clash Verge / OpenClash / NekoBox / Hiddify 即可使用，客户端会自动识别格式。

默认安装 **Xray v26.7.28**，这样 Shadowrocket、OpenClash、FlClash 可以同时使用。不要直接装 v26.9.8 及以上，原因见下文。

自定义端口或伪装域名：`PORT=8443 SNI=www.microsoft.com bash <(curl -fsSL .../reality-menu.sh) install`

指定 Xray 版本：`XRAY_VERSION=v26.7.28`（默认，可省略），`XRAY_VERSION=latest` 安装官方最新版。

不带 `install` 运行则进入交互菜单：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccav001eth/reality-menu/main/reality-menu.sh)
```

## 菜单

| 选项 | 功能 |
|---|---|
| 1 | 安装 / 重装（默认 Xray v26.7.28，自动开启订阅，生成新链接） |
| 2 | 查看订阅链接、单节点链接和二维码 |
| 3 | 查看运行状态 |
| 4 | 查看最近日志 |
| 5 | 重启服务 |
| 6 | 更新 Xray（默认 v26.7.28，可改 latest；必要时补 minClientVer） |
| 7 | 卸载（含订阅服务） |
| 8 | 开启 / 查看订阅（通用订阅链接） |
| 9 | 重置订阅地址（旧地址失效） |
| 10 | 关闭订阅 |

## Xray 版本

脚本默认安装 **Xray v26.7.28**，不跟官方最新版。一键安装和菜单选项 1、6 都是这个默认值。

**v26.9.8 及以后**，Reality 服务端会拒绝 ClientHello 里没有 `X25519MLKEM768` 的客户端。Shadowrocket（小火箭）2.2.92 不发送这个密钥：节点延迟测试可以通过，真实连接却会静默失败。固定在 v26.7.28 可以避开这个限制。

**v26.7.11 到 v26.9.7**（包括默认的 v26.7.28）在 `minClientVer` 留空时，会把最低客户端版本当成 26.3.27，OpenClash 和 FlClash（mihomo）会被拒绝。脚本发现当前装的正是这类版本时，会在 Reality 入站的 `realitySettings` 里写上 `"minClientVer": "1.0.0"`。v26.9.8 起上游已经去掉这个内置下限，这类版本不再写该字段；写了也解决不了上面的密钥问题。

安装官方最新版，或指定其它版本：

```bash
# 官方最新版。会先警告与 Shadowrocket 不兼容；一键模式下警告后仍会继续安装
XRAY_VERSION=latest bash <(curl -fsSL https://raw.githubusercontent.com/ccav001eth/reality-menu/main/reality-menu.sh) install

# 指定版本，v26.7.28 或 26.7.28 都可以
XRAY_VERSION=v26.7.28 bash <(curl -fsSL https://raw.githubusercontent.com/ccav001eth/reality-menu/main/reality-menu.sh) install
```

不带 `install` 进入菜单时，选项 1 和选项 6 也会询问版本：直接回车是 v26.7.28，输入 `latest` 是最新版，也可以填其它版本号。交互模式下如果选了 v26.9.8 及以上，需要再确认一次才会安装。已经设置环境变量 `XRAY_VERSION` 时不再询问。

选项 6 不重做密钥，也不更换订阅地址。若新版本仍带内置客户端版本下限，且现有配置里还没有 `minClientVer`，脚本只补上 `"1.0.0"`；已经手写过别的值则保持不动。补写时会把 `/usr/local/etc/xray/config.json` 重排成两空格缩进，入站参数不变。机器上如果已经升到 v26.9.8 以后、Shadowrocket 连不上，选 6 后直接回车即可降回 v26.7.28，并补上这个字段。

Xray 日志里可能出现 `Changing "minClientVer" will increase the likelihood of your server's IP being blocked by the GFW`。这是上游对修改该字段的提示，不是启动失败。不写这个字段时，OpenClash 和 FlClash 会被 v26.7.28 拒绝。

## 通用订阅

安装时自动开启（之后也可用 8 查看/开启），会生成一条 `http://服务器IP:随机端口/随机32位路径` 的订阅地址和二维码，各客户端填同一条即可：

- **Clash / Clash Verge / OpenClash / mihomo / Stash**：自动返回 Clash Meta 配置（含 reality-opts、手动选择 + 自动测速分组、局域网和国内直连）。OpenClash 需使用 Meta 内核。Clash YAML 与原来相同，不加入 `support-x25519mlkem768`。
- **v2rayN / v2rayNG / Shadowrocket（小火箭）/ NekoBox / Hiddify 及其他**：返回 Base64 编码的 `vless://` 链接，**不含** `support-x25519mlkem768=true`。这是 mihomo / Clash Meta 的 `reality-opts` 选项，写进 vless 查询参数不能让 Shadowrocket 完成握手。单节点备用链接同样不含该参数。
- 识别不准时可在地址后加 `?target=clash` 或 `?target=v2ray` 强制格式。

订阅内容在每次请求时从 `/usr/local/etc/xray/config.json` 实时生成，新增用户/UUID 后客户端点更新即可。已用旧版脚本安装的服务器也可直接选 8，不会重新生成密钥（公钥从 `/root/reality-link.txt` 读取）。

说明：
- 订阅服务是一个 python3 小服务（systemd: `reality-sub`），无需域名，走 HTTP 明文。
- 订阅地址等于节点密码，不要公开；泄露后用 9 重置。
- ufw/firewalld 开启时会自动放行端口；云服务商安全组需自行放行。
