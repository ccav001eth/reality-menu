#!/usr/bin/env bash
# 梯哥 VLESS + Reality 管理菜单（基于 XTLS 官方安装脚本）
# 用法：root 执行  bash reality-menu.sh
# 环境变量：PORT、SNI、XRAY_VERSION（默认 v26.7.28；latest 为官方最新版）
CONF=/usr/local/etc/xray/config.json
LINKF=/root/reality-link.txt
PUBF=/usr/local/etc/xray/reality-pub.txt
SUBDIR=/usr/local/etc/reality-sub
SUBENV=$SUBDIR/sub.env
SUBPY=$SUBDIR/sub-server.py
SUBSVC=/etc/systemd/system/reality-sub.service
OFFICIAL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
# v26.7.28 是仍接受 Shadowrocket 的版本：v26.9.8 起 Reality 拒绝不含 X25519MLKEM768 的 ClientHello。
# v26.7.11–v26.9.7 在 minClientVer 为空时内置下限 26.3.27，需写成 1.0.0 才能放行 OpenClash / FlClash。
XRAY_PIN=v26.7.28
XRAY_MINCLIENT_FROM=26.7.11
XRAY_MLKEM_FROM=26.9.8
if [ -n "${XRAY_VERSION+x}" ]; then XRAY_VERSION_SET=1; else XRAY_VERSION_SET=0; XRAY_VERSION=$XRAY_PIN; fi
[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }

need(){ command -v "$1" >/dev/null || apt-get install -y "$1" >/dev/null 2>&1 || yum install -y "$1" >/dev/null 2>&1; }

show_link(){
  [ -f "$LINKF" ] || { echo "没有找到 $LINKF（可能不是用本脚本部署的）"; return; }
  echo; cat "$LINKF"; echo
  need qrencode; command -v qrencode >/dev/null && qrencode -t ansiutf8 "$(cat $LINKF)"
  if [ -f "$SUBENV" ] && systemctl is-active --quiet reality-sub; then sub_show; else echo "订阅未开启，可选 8 开启"; fi
}

get_ip(){ curl -4 -s --max-time 8 https://ifconfig.me || hostname -I | awk '{print $1}'; }

write_sub_server(){
  mkdir -p "$SUBDIR"; chmod 700 "$SUBDIR"
  cat > "$SUBPY" <<'PYEOF'
#!/usr/bin/env python3
# 梯哥 Reality 通用订阅服务：按 User-Agent 返回 Clash Meta yaml 或 base64 vless 链接
import base64, json, os, re, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ENV = {}
for l in open("/usr/local/etc/reality-sub/sub.env"):
    if "=" in l:
        k, v = l.strip().split("=", 1); ENV[k] = v
CONF = "/usr/local/etc/xray/config.json"
CLASH_UA = re.compile(r"clash|mihomo|meta|stash|openclash|verge", re.I)

def pubkey():
    try:
        p = open("/usr/local/etc/xray/reality-pub.txt").read().strip()
        if p: return p
    except Exception: pass
    m = re.search(r"pbk=([^&#\s]+)", open("/root/reality-link.txt").read())
    return m.group(1)

def nodes():
    c = json.load(open(CONF)); pbk = pubkey(); ip = ENV["IP"]; out = []
    for ib in c.get("inbounds", []):
        ss = ib.get("streamSettings", {})
        if ib.get("protocol") != "vless" or ss.get("security") != "reality": continue
        r = ss["realitySettings"]; sni = r["serverNames"][0]; sid = (r.get("shortIds") or [""])[0]
        cl = ib["settings"]["clients"]
        for i, u in enumerate(cl):
            name = "Reality-%s-%s" % (ip, ib["port"]) + ("" if len(cl) == 1 else "-%d" % (i + 1))
            out.append(dict(name=name, ip=ip, port=ib["port"], uuid=u["id"], flow=u.get("flow", ""), sni=sni, pbk=pbk, sid=sid))
    return out

def v2ray(ns):
    # 不写 support-x25519mlkem768。那是 mihomo 的 reality-opts，放进 vless:// 不能让 Shadowrocket 握手。
    # Clash YAML 保持原样，不加入该字段。
    links = []
    for n in ns:
        q = urllib.parse.urlencode(dict(encryption="none", flow=n["flow"], security="reality", sni=n["sni"], fp="chrome", pbk=n["pbk"], sid=n["sid"], type="tcp"))
        links.append("vless://%s@%s:%s?%s#%s" % (n["uuid"], n["ip"], n["port"], q, urllib.parse.quote(n["name"])))
    return base64.b64encode("\n".join(links).encode()).decode()

def clash(ns):
    y = ["mixed-port: 7890", "allow-lan: true", "mode: rule", "log-level: info", "proxies:"]
    for n in ns:
        y += ['  - name: "%s"' % n["name"], "    type: vless", "    server: %s" % n["ip"], "    port: %s" % n["port"],
              "    uuid: %s" % n["uuid"], "    network: tcp", "    tls: true", "    udp: true"]
        if n["flow"]: y.append("    flow: %s" % n["flow"])
        y += ["    servername: %s" % n["sni"], "    client-fingerprint: chrome", "    reality-opts:",
              "      public-key: %s" % n["pbk"], '      short-id: "%s"' % n["sid"]]
    names = ", ".join('"%s"' % n["name"] for n in ns)
    y += ["proxy-groups:", '  - name: "PROXY"', "    type: select", '    proxies: ["AUTO", %s, DIRECT]' % names,
          '  - name: "AUTO"', "    type: url-test", "    url: http://www.gstatic.com/generate_204", "    interval: 300",
          "    proxies: [%s]" % names,
          "rules:", "  - DOMAIN-SUFFIX,local,DIRECT", "  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve", "  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
          "  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve", "  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve", "  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
          "  - GEOIP,LAN,DIRECT,no-resolve", "  - GEOIP,CN,DIRECT", "  - MATCH,PROXY"]
    return "\n".join(y) + "\n"

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path.rstrip("/") != "/" + ENV["SUBPATH"]:
            self.send_response(404); self.end_headers(); return
        t = urllib.parse.parse_qs(u.query).get("target", [""])[0].lower()
        ua = self.headers.get("User-Agent", "")
        is_clash = t == "clash" or (t != "v2ray" and bool(CLASH_UA.search(ua)))
        try:
            ns = nodes(); body = (clash(ns) if is_clash else v2ray(ns)).encode()
        except Exception:
            self.send_response(500); self.end_headers(); return
        self.send_response(200)
        self.send_header("Content-Type", "text/yaml; charset=utf-8" if is_clash else "text/plain; charset=utf-8")
        self.send_header("Content-Disposition", "attachment; filename*=UTF-8''%s" % ("Reality.yaml" if is_clash else "Reality.txt"))
        self.send_header("profile-update-interval", "24")
        self.send_header("Subscription-Userinfo", "upload=0; download=0; total=0; expire=0")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

ThreadingHTTPServer(("0.0.0.0", int(ENV["SUBPORT"])), H).serve_forever()
PYEOF
  chmod 700 "$SUBPY"
  cat > "$SUBSVC" <<SVCEOF
[Unit]
Description=Reality subscription server
After=network.target
[Service]
ExecStart=/usr/bin/env python3 $SUBPY
Restart=always
[Install]
WantedBy=multi-user.target
SVCEOF
}

sub_url(){ . "$SUBENV"; echo "http://$IP:$SUBPORT/$SUBPATH"; }

sub_show(){
  . "$SUBENV"; local U; U=$(sub_url)
  echo
  echo "=============================================================="
  echo " ★ 通用订阅链接（v2rayN / v2rayNG / 小火箭 / Clash Verge / OpenClash / NekoBox / Hiddify）"
  echo "   $U"
  echo "=============================================================="
  echo "强制 Clash 格式: $U?target=clash"
  echo "强制 V2Ray 格式: $U?target=v2ray"
  need qrencode; command -v qrencode >/dev/null && qrencode -t ansiutf8 "$U"
  echo "订阅地址等同于节点密码，请勿公开。云服务商若有安全组，记得放行 $SUBPORT/TCP"
}

sub_open_port(){
  command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active" && ufw allow "$1"/tcp >/dev/null
  command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1 && { firewall-cmd --permanent --add-port="$1"/tcp >/dev/null; firewall-cmd --reload >/dev/null; }
}
sub_close_port(){
  command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active" && ufw delete allow "$1"/tcp >/dev/null 2>&1
  command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1 && { firewall-cmd --permanent --remove-port="$1"/tcp >/dev/null 2>&1; firewall-cmd --reload >/dev/null; }
}

sub_enable(){
  [ -f "$CONF" ] || { echo "请先安装 Reality（选项 1）"; return; }
  if [ ! -s "$PUBF" ]; then
    P=$(grep -o 'pbk=[^&#]*' "$LINKF" 2>/dev/null | head -n1 | cut -d= -f2)
    [ -n "$P" ] || { echo "找不到公钥（$PUBF 或 $LINKF），无法生成订阅"; return; }
    echo "$P" > "$PUBF"; chmod 600 "$PUBF"
  fi
  need python3; command -v python3 >/dev/null || { echo "python3 安装失败"; return; }
  if [ ! -f "$SUBENV" ]; then
    mkdir -p "$SUBDIR"; chmod 700 "$SUBDIR"
    SP=$(shuf -i 20000-60000 -n 1)
    SPATH=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    printf 'IP=%s\nSUBPORT=%s\nSUBPATH=%s\n' "$(get_ip)" "$SP" "$SPATH" > "$SUBENV"; chmod 600 "$SUBENV"
  fi
  write_sub_server
  . "$SUBENV"; sub_open_port "$SUBPORT"
  systemctl daemon-reload; systemctl enable reality-sub >/dev/null 2>&1; systemctl restart reality-sub; sleep 1
  systemctl is-active --quiet reality-sub || { echo "订阅服务启动失败："; journalctl -u reality-sub -n 20 --no-pager; return; }
  sub_show
}

sub_reset(){
  [ -f "$SUBENV" ] || { echo "订阅未开启"; return; }
  . "$SUBENV"; sub_close_port "$SUBPORT"; rm -f "$SUBENV"
  echo "已重置，旧订阅地址失效，请在客户端换成新地址"; sub_enable
}

sub_disable(){
  systemctl disable --now reality-sub >/dev/null 2>&1
  [ -f "$SUBENV" ] && { . "$SUBENV"; sub_close_port "$SUBPORT"; }
  rm -f "$SUBSVC"; rm -rf "$SUBDIR"; systemctl daemon-reload
  echo "订阅已关闭"
}

normalize_xray_version(){
  local raw low
  raw=$(printf '%s' "$1" | tr -d '[:space:]')
  low=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  if [ "$low" = latest ]; then printf '%s\n' latest; return; fi
  if [ -z "$raw" ]; then printf '%s\n' "$XRAY_PIN"; return; fi
  printf 'v%s\n' "${raw#[vV]}"
}

ver_ge(){
  local a="${1#[vV]}" b="${2#[vV]}"
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" = "$b" ]
}

version_needs_min_client(){
  local v
  [ "$1" = latest ] && return 1
  v="${1#[vV]}"
  ver_ge "$v" "$XRAY_MINCLIENT_FROM" || return 1
  ver_ge "$v" "$XRAY_MLKEM_FROM" && return 1
  return 0
}

version_breaks_shadowrocket(){
  [ "$1" = latest ] && return 0
  ver_ge "${1#[vV]}" "$XRAY_MLKEM_FROM"
}

xray_installed_version(){
  local line ver
  line=$(xray version 2>/dev/null | head -n1)
  [ -n "$line" ] || line=$(xray -version 2>/dev/null | head -n1)
  [ -n "$line" ] || return 1
  ver=$(printf '%s\n' "$line" | awk '{print $2}')
  [ -n "$ver" ] || return 1
  printf 'v%s\n' "${ver#[vV]}"
}

resolve_xray_version(){
  local got
  got=$(xray_installed_version || true)
  if [ -n "$got" ]; then
    printf '%s\n' "$got"
  elif [ "$XRAY_CHOSEN" != latest ]; then
    printf '%s\n' "$XRAY_CHOSEN"
  fi
}

warn_shadowrocket(){
  echo
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo " 警告：此 Xray 版本与 Shadowrocket（小火箭）不兼容"
  echo " v${XRAY_MLKEM_FROM} 起 Reality 会拒绝 ClientHello 中不含 X25519MLKEM768 的客户端。"
  echo " Shadowrocket 2.2.92 不发送该密钥：延迟测试可以通过，实际连接会静默失败。"
  echo " 要同时兼容 Shadowrocket、OpenClash、FlClash，请安装固定版本 ${XRAY_PIN}。"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo
}

select_xray_version(){
  local ans
  if [ "$XRAY_VERSION_SET" = 1 ] || [ "$AUTO" = 1 ]; then
    XRAY_CHOSEN=$XRAY_VERSION
    return 0
  fi
  echo "Xray 默认固定 ${XRAY_PIN}：可同时兼容 Shadowrocket、OpenClash、FlClash。"
  echo "直接回车使用该版本；输入 latest 安装官方最新版；也可输入其它版本号，例如 v26.6.27。"
  echo "注意：v${XRAY_MLKEM_FROM} 及以上会拒绝不含 X25519MLKEM768 的 ClientHello，Shadowrocket 2.2.92 延迟测试能过但连接会静默失败。"
  read -rp "Xray 版本 [${XRAY_PIN}]: " ans
  XRAY_CHOSEN=$(normalize_xray_version "${ans:-$XRAY_PIN}")
}

prepare_xray_install(){
  local a
  select_xray_version
  if version_breaks_shadowrocket "$XRAY_CHOSEN"; then
    warn_shadowrocket
    if [ "$AUTO" != 1 ] && [ "$XRAY_VERSION_SET" != 1 ]; then
      read -rp "仍要安装该版本？(y/N) " a
      [ "$a" = y ] || [ "$a" = Y ] || { echo "已取消"; return 1; }
    fi
  elif version_needs_min_client "$XRAY_CHOSEN"; then
    echo "该版本在 minClientVer 为空时会拒绝 OpenClash / FlClash。安装后将把 Reality 的 minClientVer 设为 1.0.0。"
  fi
  echo "将安装 Xray ${XRAY_CHOSEN}"
}

install_xray(){
  local script
  need curl
  script=$(curl -fsSL "$OFFICIAL") || { echo "下载 Xray 安装脚本失败"; return 1; }
  if [ "$1" = latest ]; then
    bash -c "$script" @ install
  else
    bash -c "$script" @ install --version "$1"
  fi
}

apply_min_client_ver(){
  [ -f "$CONF" ] || { echo "没有找到 $CONF，未写入 minClientVer"; return 1; }
  need python3
  command -v python3 >/dev/null || { echo "python3 不可用，未能写入 minClientVer"; return 1; }
  python3 - "$CONF" <<'MINPY'
import json, os, stat, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
    changed = False
    seen = False
    kept = []
    for ib in cfg.get("inbounds") or []:
        ss = ib.get("streamSettings") or {}
        if ib.get("protocol") != "vless" or ss.get("security") != "reality":
            continue
        seen = True
        rs = ss.setdefault("realitySettings", {})
        cur = rs.get("minClientVer")
        if cur is None:
            rs["minClientVer"] = "1.0.0"
            changed = True
        elif cur != "1.0.0":
            kept.append(str(cur))
    if changed:
        st = os.stat(path)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.chmod(tmp, stat.S_IMODE(st.st_mode))
        os.chown(tmp, st.st_uid, st.st_gid)
        os.replace(tmp, path)
        print("已写入 minClientVer 1.0.0")
        if kept:
            print("其余入站的 minClientVer 已设置为 %s，保持不变" % ", ".join(kept))
    elif not seen:
        print("配置中没有 Reality 入站，未写入 minClientVer")
    elif kept:
        print("minClientVer 已设置为 %s，保持不变" % ", ".join(kept))
    else:
        print("minClientVer 已是 1.0.0，配置未改")
except Exception as e:
    print("更新 minClientVer 失败：%s" % e, file=sys.stderr)
    sys.exit(1)
MINPY
}

deploy(){
  local installed minclient=""
  if [ "$AUTO" = 1 ]; then PORT=${PORT:-443}; SNI=${SNI:-www.microsoft.com}; else
  read -rp "端口 [443]: " PORT; PORT=${PORT:-443}
  read -rp "伪装域名 [www.microsoft.com]: " SNI; SNI=${SNI:-www.microsoft.com}
  fi
  if [ -f "$CONF" ] && [ "$AUTO" != 1 ]; then
    read -rp "已有配置，继续会生成新密钥、旧链接失效，确定？(y/N) " a; [ "$a" = y ] || return
  fi
  prepare_xray_install || return
  apt-get update >/dev/null 2>&1; need curl; need openssl
  install_xray "$XRAY_CHOSEN" || { echo "安装失败"; return; }
  installed=$(resolve_xray_version)
  if [ -n "$installed" ] && version_needs_min_client "$installed"; then
    minclient=', "minClientVer": "1.0.0"'
    echo "当前 Xray：$installed，将写入 minClientVer 1.0.0"
  elif [ -n "$installed" ]; then
    echo "当前 Xray：$installed"
  else
    echo "无法读取已安装的 Xray 版本，未写入 minClientVer。若 OpenClash / FlClash 被拒绝，请在 realitySettings 中加入 \"minClientVer\": \"1.0.0\" 后重启 Xray。"
  fi
  UUID=$(xray uuid)
  KEYS=$(xray x25519)
  PRIV=$(echo "$KEYS" | awk -F': ' '/Private/{print $2}')
  PUB=$(echo "$KEYS" | awk -F': ' '/Public|Password/{print $2}' | head -n1)
  SID=$(openssl rand -hex 8)
  cat > "$CONF" <<CONFEOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0", "port": $PORT, "protocol": "vless",
    "settings": {"clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}], "decryption": "none"},
    "streamSettings": {"network": "tcp", "security": "reality",
      "realitySettings": {"dest": "$SNI:443", "serverNames": ["$SNI"], "privateKey": "$PRIV", "shortIds": ["$SID"]$minclient}},
    "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
CONFEOF
  grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf || { echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf; echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf; }
  sysctl -p >/dev/null 2>&1
  command -v ufw >/dev/null && ufw allow "$PORT"/tcp >/dev/null
  command -v firewall-cmd >/dev/null && { firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null; firewall-cmd --reload >/dev/null; }
  systemctl enable xray >/dev/null 2>&1; systemctl restart xray; sleep 1
  systemctl is-active --quiet xray || { echo "Xray 启动失败："; journalctl -u xray -n 20 --no-pager; return; }
  IP=$(curl -4 -s https://ifconfig.me || hostname -I | awk '{print $1}')
  # 单节点链接与订阅里的 vless:// 一样，不带 support-x25519mlkem768
  echo "vless://$UUID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID&type=tcp#Reality-$IP" > "$LINKF"
  chmod 600 "$LINKF"
  echo "$PUB" > "$PUBF"; chmod 600 "$PUBF"
  systemctl is-active --quiet reality-sub && systemctl restart reality-sub
  echo; echo "== 部署完成，正在开启通用订阅 =="
  sub_enable
  echo; echo "== 单节点链接（备用，可直接导入）=="; cat "$LINKF"
  echo "云服务商若有安全组，记得放行 $PORT/TCP"
}

# 一键模式：bash reality-menu.sh install
# 环境变量：PORT、SNI、XRAY_VERSION（默认 v26.7.28；latest 为官方最新版）
if [ "$XRAY_VERSION_SET" = 1 ]; then XRAY_VERSION=$(normalize_xray_version "$XRAY_VERSION"); fi
if [ "$1" = install ]; then AUTO=1; deploy; exit 0; fi

update_xray(){
  local installed
  prepare_xray_install || return
  install_xray "$XRAY_CHOSEN" || { echo "更新失败"; return; }
  installed=$(resolve_xray_version)
  if [ -n "$installed" ]; then echo "当前 Xray：$installed"; else echo "无法读取已安装的 Xray 版本，未修改 minClientVer。"; fi
  if [ -n "$installed" ] && version_needs_min_client "$installed"; then
    apply_min_client_ver || echo "写入 minClientVer 失败，请手动在 realitySettings 中加入 \"minClientVer\": \"1.0.0\""
  fi
  systemctl restart xray && echo "已重启"
}

while true; do
  echo
  echo "====== 梯哥 Reality 管理 ======"
  echo " 1. 安装 / 重装（默认 Xray ${XRAY_PIN}，自动开启订阅）"
  echo " 2. 查看导入链接和二维码"
  echo " 3. 查看运行状态"
  echo " 4. 查看最近日志"
  echo " 5. 重启服务"
  echo " 6. 更新 Xray（默认 ${XRAY_PIN}，可选最新版）"
  echo " 7. 卸载（含订阅服务）"
  echo " 8. 开启 / 查看订阅（通用订阅链接）"
  echo " 9. 重置订阅地址"
  echo "10. 关闭订阅"
  echo " 0. 退出"
  read -rp "请选择: " c
  case $c in
    1) deploy ;;
    2) show_link ;;
    3) systemctl status xray --no-pager ;;
    4) journalctl -u xray -n 50 --no-pager ;;
    5) systemctl restart xray && echo "已重启" ;;
    6) update_xray ;;
    7) read -rp "确定卸载并删除配置？(y/N) " a; [ "$a" = y ] && bash -c "$(curl -L $OFFICIAL)" @ remove --purge && { sub_disable; rm -f "$LINKF" "$PUBF"; } ;;
    8) sub_enable ;;
    9) sub_reset ;;
    10) sub_disable ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done
