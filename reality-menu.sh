#!/usr/bin/env bash
# 梯哥 VLESS + Reality 管理菜单（基于 XTLS 官方安装脚本）
# 用法：root 执行  bash reality-menu.sh
CONF=/usr/local/etc/xray/config.json
LINKF=/root/reality-link.txt
PUBF=/usr/local/etc/xray/reality-pub.txt
SUBDIR=/usr/local/etc/reality-sub
SUBENV=$SUBDIR/sub.env
SUBPY=$SUBDIR/sub-server.py
SUBSVC=/etc/systemd/system/reality-sub.service
OFFICIAL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
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

deploy(){
  if [ "$AUTO" = 1 ]; then PORT=${PORT:-443}; SNI=${SNI:-www.microsoft.com}; else
  read -rp "端口 [443]: " PORT; PORT=${PORT:-443}
  read -rp "伪装域名 [www.microsoft.com]: " SNI; SNI=${SNI:-www.microsoft.com}
  fi
  if [ -f "$CONF" ] && [ "$AUTO" != 1 ]; then
    read -rp "已有配置，继续会生成新密钥、旧链接失效，确定？(y/N) " a; [ "$a" = y ] || return
  fi
  apt-get update >/dev/null 2>&1; need curl; need openssl
  bash -c "$(curl -L $OFFICIAL)" @ install || { echo "安装失败"; return; }
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
      "realitySettings": {"dest": "$SNI:443", "serverNames": ["$SNI"], "privateKey": "$PRIV", "shortIds": ["$SID"]}},
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
  echo "vless://$UUID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID&type=tcp#Reality-$IP" > "$LINKF"
  chmod 600 "$LINKF"
  echo "$PUB" > "$PUBF"; chmod 600 "$PUBF"
  systemctl is-active --quiet reality-sub && systemctl restart reality-sub
  echo; echo "== 部署完成，正在开启通用订阅 =="
  sub_enable
  echo; echo "== 单节点链接（备用，可直接导入）=="; cat "$LINKF"
  echo "云服务商若有安全组，记得放行 $PORT/TCP"
}

# 一键模式：bash reality-menu.sh install  （可用环境变量 PORT、SNI 指定端口和伪装域名）
if [ "$1" = install ]; then AUTO=1; deploy; exit 0; fi

while true; do
  echo
  echo "====== 梯哥 Reality 管理 ======"
  echo " 1. 安装 / 重装（自动开启订阅）"
  echo " 2. 查看导入链接和二维码"
  echo " 3. 查看运行状态"
  echo " 4. 查看最近日志"
  echo " 5. 重启服务"
  echo " 6. 更新 Xray（配置不变）"
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
    6) bash -c "$(curl -L $OFFICIAL)" @ install && systemctl restart xray ;;
    7) read -rp "确定卸载并删除配置？(y/N) " a; [ "$a" = y ] && bash -c "$(curl -L $OFFICIAL)" @ remove --purge && { sub_disable; rm -f "$LINKF" "$PUBF"; } ;;
    8) sub_enable ;;
    9) sub_reset ;;
    10) sub_disable ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done
