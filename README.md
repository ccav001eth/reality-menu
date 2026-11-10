# reality-menu

VLESS + Reality 一键管理菜单（基于 XTLS 官方安装脚本），带**通用订阅**。新装默认按 Xray 社区习惯做基础加固：伪装域名、路由黑洞、fail2ban。可选项默认都关闭。

## 一条命令

在 VPS 上用 root 运行（全自动。默认 TCP 443、伪装域名 `addons.mozilla.org`、Xray v26.7.28）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccav001eth/reality-menu/main/reality-menu.sh) install
```

装完会显示**通用订阅链接 + 二维码**，另附单节点 vless 链接。导入 v2rayN / v2rayNG / Shadowrocket（小火箭）/ Clash Verge / OpenClash / NekoBox / Hiddify 即可。客户端指纹是 `chrome`。

不带 `install` 则进入交互菜单；选项 1 会询问端口、伪装域名和下面的可选项。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccav001eth/reality-menu/main/reality-menu.sh)
```

## 默认会做的事

- Reality `dest` / `serverNames` 使用 `addons.mozilla.org:443`。以前的 `www.microsoft.com` 在部分机器上握手失败。
- 客户端链接和订阅里的指纹是 `chrome`（`fp=chrome`、`client-fingerprint: chrome`）。
- 入站嗅探 `http`、`tls`、`quic`。出站第一条是 `freedom`，标签 `direct`（默认出站）。`bittorrent` 和 `geoip:private` 送到标签 `block` 的 `blackhole`。`domainStrategy` 是 `IPIfNonMatch`，这样域名目标也能套用 IP 规则。
- 安装并启用 fail2ban 的 sshd 监狱：SSH 端口从 `sshd -T` 读取；白名单是 `127.0.0.1/8`、`::1` 和当前 `SSH_CLIENT`。日志看 journal 还是 `auth.log` / `secure`，封禁用 nftables、iptables、ufw 还是 firewalld，都按机器上实际有的来。Debian 上 ssh 单元是 `ssh.service`，RHEL 系是 `sshd.service`，journalmatch 会写成检测到的那个，并带上 `_COMM=sshd` 和 `_COMM=sshd-session`。走 journal 时会安装 `python3-systemd`。
- 写入配置前先备份。`xray run -test` 失败就回滚，不会带着坏配置重启。

fail2ban、证书、隧道、Hysteria2 任一步检测不到或安装失败，只打印警告，然后继续。不会因为加固失败把 Reality 装挂。

## 环境变量

交互安装会把已设置的变量当成提问的默认值。`install` 不再提问。

| 变量 | 默认 | 含义 |
|---|---|---|
| `PORT` | `443` | Reality 的 TCP 端口 |
| `SNI` | `addons.mozilla.org` | `dest` 和 `serverNames` |
| `XRAY_VERSION` | `v26.7.28` | `latest` 为官方最新版 |
| `FAIL2BAN` | 开启 | `0` / `false` / `no` / `off` 跳过 |
| `HYSTERIA2` | `0` | `1` 安装官方 apernet Hysteria2 备用节点 |
| `HY2_PORT` | 随机高位 UDP | 不能是 443 |
| `HY2_HOP` | `0` | `1` 用 nftables 或 iptables 把一段 UDP DNAT 到监听端口 |
| `HY2_HOP_RANGE` | `20000-50000` | 不能包含 443 |
| `DISABLE_SSH_PASSWORD` | `0` | `1` 关闭 SSH 密码登录。没有任何公钥就拒绝 |
| `SUB_TUNNEL` | `0` | `1` 订阅只听 `127.0.0.1`，用 Cloudflare Quick Tunnel 给 HTTPS |
| `BLOCK_CN` | `0` | `1` 把 `geoip:cn` / `geosite:cn` 送进黑洞 |

示例：

```bash
# 换伪装域名，并跳过 fail2ban
SNI=www.cloudflare.com FAIL2BAN=0 bash <(curl -fsSL https://raw.githubusercontent.com/ccav001eth/reality-menu/main/reality-menu.sh) install

# 带 Hysteria2 和端口跳跃。Reality 仍然在 TCP 443
HYSTERIA2=1 HY2_HOP=1 bash <(curl -fsSL https://raw.githubusercontent.com/ccav001eth/reality-menu/main/reality-menu.sh) install

# 订阅改走 Quick Tunnel；明文 HTTP 不再对公网开放
SUB_TUNNEL=1 bash <(curl -fsSL https://raw.githubusercontent.com/ccav001eth/reality-menu/main/reality-menu.sh) install
```

再跑一次 `install` 会换 Reality 密钥。已经装过的 Hysteria2（带 `reality-menu managed` 标记）不会轮换密码和端口。`HY2_HOP` 没写时保留原来的跳跃设置；写了 `0` 或 `1` 才改。`BLOCK_CN` 没写时沿用现有配置。

## 不会做的事

- 不跑 `apt full-upgrade` / `dist-upgrade`，只在缺包时安装需要的包。
- 不改内核，不重启机器。BBR 仍只是写入 sysctl，和以前一样。
- 不自动升级 Xray。选项 6 才换版本，默认还是 v26.7.28。
- 不把 Reality 从 TCP 443 挪走。`PORT` 仍可自己指定。
- 不默认开启 `limitFallback`。
- vless 链接和订阅里不写 `support-x25519mlkem768`。

## 菜单

| 选项 | 功能 |
|---|---|
| 1 | 安装 / 重装（默认 Xray v26.7.28、dest `addons.mozilla.org`，自动开启订阅，生成新链接） |
| 2 | 查看订阅链接、单节点链接、Hysteria2 链接和二维码 |
| 3 | 查看运行状态 |
| 4 | 查看最近日志 |
| 5 | 测试配置通过后再重启 |
| 6 | 更新 Xray（默认 v26.7.28，可改 latest；必要时补 minClientVer）。不改路由、不轮换密钥 |
| 7 | 卸载（含订阅、本脚本的隧道、Hysteria2、fail2ban 片段和 SSH 限制）。不卸载 fail2ban 软件包 |
| 8 | 开启 / 查看订阅 |
| 9 | 重置订阅地址（旧地址失效） |
| 10 | 关闭订阅 |
| 11 | 下载 XTLS/RealiTLScanner，扫描本机公网 IP 所在 /24 或你给的 CIDR，列出 TLS1.3 + h2 且 HTTPS 不跳转的域名，可选用其中一个换 dest |

选项 11 可能要很久。只接受 CIDR。单个 IP 会让 RealiTLScanner 停不下来，所以直接拒绝。大于 /24 会再确认一次。换 dest 之前备份配置，`xray run -test` 失败就恢复，不改端口、密钥和 flow。

## 可选项

**Hysteria2。** 下载 GitHub 上 apernet/hysteria 的官方二进制，监听随机高位 UDP（不是 443），自签证书，masquerade 反代到当前伪装域名。可选端口跳跃：优先 nftables，否则 iptables/ip6tables，把 `HY2_HOP_RANGE` DNAT 到那个 UDP 端口，并写成开机恢复的 systemd 服务。订阅里会多一条 `hysteria2://`，Clash 里在跳跃时带 `ports` 和 `hop-interval`。不改 Reality 入站，也不占用 TCP 443。已有别人写的 `/etc/hysteria/config.yaml` 时跳过。

**关闭 SSH 密码。** 只有某个用户的 `authorized_keys` 里至少有一把公钥，并且 `PubkeyAuthentication` 不是 no，才会写 `/etc/ssh/sshd_config.d/00-reality-menu-password.conf`。`sshd -t` 失败，或生效结果仍允许密码，就整份回滚。用 reload，不 restart。装完后请另开一个终端确认能登录。

**订阅隧道。** 默认仍是 `http://服务器IP:随机端口/随机路径`，并打印明文警告：订阅地址等于节点密码。`SUB_TUNNEL=1` 时订阅只绑 `127.0.0.1`，cloudflared quick tunnel 提供 `https://*.trycloudflare.com/...`。这个域名在 `reality-tunnel` 重启后会变，客户端要更新。隧道起不来就退回明文，避免订阅直接不可用。

**屏蔽大陆地址。** 默认否。打开后，经本节点访问中国大陆网站会进黑洞。这和客户端配置里的 `GEOIP,CN,DIRECT` 不是一回事：那条是让客户端自己直连，服务器规则是节点不再转发这类目标。

## Xray 版本

脚本默认安装 **Xray v26.7.28**，不跟官方最新版。一键安装和菜单选项 1、6 都是这个默认值。

**v26.9.8 及以后**，Reality 服务端会拒绝 ClientHello 里没有 `X25519MLKEM768` 的客户端。Shadowrocket（小火箭）2.2.92 不发送这个密钥：节点延迟测试可以通过，真实连接却会静默失败。固定在 v26.7.28 可以避开这个限制。链接里也不会写 `support-x25519mlkem768`。

**v26.7.11 到 v26.9.7**（包括默认的 v26.7.28）在 `minClientVer` 留空时，会把最低客户端版本当成 26.3.27，OpenClash 和 FlClash（mihomo）会被拒绝。脚本发现当前装的正是这类版本时，会在 Reality 入站的 `realitySettings` 里写上 `"minClientVer": "1.0.0"`。v26.9.8 起上游已经去掉这个内置下限，这类版本不再写该字段。

```bash
# 官方最新版。会先警告与 Shadowrocket 不兼容；一键模式下警告后仍会继续安装
XRAY_VERSION=latest bash <(curl -fsSL https://raw.githubusercontent.com/ccav001eth/reality-menu/main/reality-menu.sh) install

# 指定版本，v26.7.28 或 26.7.28 都可以
XRAY_VERSION=v26.7.28 bash <(curl -fsSL https://raw.githubusercontent.com/ccav001eth/reality-menu/main/reality-menu.sh) install
```

不带 `install` 进入菜单时，选项 1 和选项 6 也会询问版本。已经设置 `XRAY_VERSION` 时不再询问。选了 v26.9.8 及以上时，交互模式要再确认一次。

选项 6 不重做密钥，也不更换订阅地址。若新版本仍带内置客户端版本下限，且现有配置里还没有 `minClientVer`，脚本只补上 `"1.0.0"`；已经手写过别的值则保持不动。补写前备份，测试失败会回滚。机器上如果已经升到 v26.9.8 以后、Shadowrocket 连不上，选 6 后直接回车即可降回 v26.7.28。

Xray 日志里可能出现 `Changing "minClientVer" will increase the likelihood of your server's IP being blocked by the GFW`。这是上游对修改该字段的提示，不是启动失败。

## 通用订阅

安装时自动开启（之后也可用 8 查看/开启）。默认是一条 `http://服务器IP:随机端口/随机32位路径`，各客户端填同一条即可：

- **Clash / Clash Verge / OpenClash / mihomo / Stash**：Clash Meta 配置（reality-opts、指纹 chrome、手动选择 + 自动测速、局域网和国内直连）。OpenClash 需使用 Meta 内核。不加入 `support-x25519mlkem768`。若装了 Hysteria2，代理列表里会多一个 hysteria2 节点。
- **v2rayN / v2rayNG / Shadowrocket / NekoBox / Hiddify**：Base64 的 `vless://`，`fp=chrome`，不含 mlkem 参数。有 Hysteria2 时再加一条 `hysteria2://`。
- 识别不准时在地址后加 `?target=clash` 或 `?target=v2ray`。

订阅在每次请求时从 `/usr/local/etc/xray/config.json` 生成。Hysteria2 参数在 `/etc/hysteria/reality-menu.env`。公钥优先读 `/usr/local/etc/xray/reality-pub.txt`，没有则从 `/root/reality-link.txt` 取。

说明：

- 订阅服务是 python3（systemd: `reality-sub`）。默认 HTTP 明文，脚本会警告。
- 订阅地址等于节点密码，不要公开；泄露后用 9 重置。
- ufw / firewalld 处于开启状态时会放行端口。云服务商安全组需要自己放行。
- fail2ban 只加 `/etc/fail2ban/jail.d/zz-reality-menu.local`，不覆盖你原有的 `jail.local`。卸载选项 7 会删掉这个片段，不会卸载 fail2ban 本身。
