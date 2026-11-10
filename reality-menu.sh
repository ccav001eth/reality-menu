#!/usr/bin/env bash
# 梯哥 VLESS + Reality 管理菜单（基于 XTLS 官方安装脚本）
# 用法：root 执行  bash reality-menu.sh
#       一键安装    bash reality-menu.sh install
#
# 环境变量（非交互 install 时读取；交互菜单里选项 1 会询问，并把这里的值当作默认）：
#   PORT                    Reality 端口，默认 443
#   SNI                     dest / serverNames，默认 addons.mozilla.org
#   XRAY_VERSION            默认 v26.7.28；latest 为官方最新版
#   FAIL2BAN                默认开启。0/false/no/off 跳过（失败也只告警，不中断安装）
#   HYSTERIA2               默认 0。1 安装官方 Hysteria2 备用节点（不改 Reality 入站）
#   HY2_PORT                Hysteria2 UDP 端口，默认随机高位，不能是 443
#   HY2_HOP                 默认 0。1 用 nftables 或 iptables 做 UDP 端口跳跃
#   HY2_HOP_RANGE           默认 20000-50000，不能包含 443
#   DISABLE_SSH_PASSWORD    默认 0。1 关闭 SSH 密码登录；没有公钥则拒绝
#   SUB_TUNNEL              默认 0。1 订阅只听 127.0.0.1，并用 Cloudflare Quick Tunnel 给 HTTPS
#   BLOCK_CN                默认 0。1 把 geoip:cn / geosite:cn 送进黑洞（国内网站经本节点将打不开）
#
# 不会做：apt full-upgrade、改内核、重启机器、自动升级 Xray、把 Reality 挪离 443、默认开启 limitFallback。
CONF=${CONF:-/usr/local/etc/xray/config.json}
LINKF=${LINKF:-/root/reality-link.txt}
PUBF=${PUBF:-/usr/local/etc/xray/reality-pub.txt}
SUBDIR=${SUBDIR:-/usr/local/etc/reality-sub}
SUBENV=${SUBENV:-$SUBDIR/sub.env}
SUBPY=${SUBPY:-$SUBDIR/sub-server.py}
SUBSVC=${SUBSVC:-/etc/systemd/system/reality-sub.service}
HYENV=${HYENV:-/etc/hysteria/reality-menu.env}
HYCONF=${HYCONF:-/etc/hysteria/config.yaml}
HYLINK=${HYLINK:-/root/hysteria-link.txt}
F2B_JAIL=${F2B_JAIL:-/etc/fail2ban/jail.d/zz-reality-menu.local}
SCANNER=${SCANNER:-/usr/local/lib/reality-menu/RealiTLScanner}
HOP_ENV=${HOP_ENV:-/usr/local/lib/reality-menu/hy2-hop.env}
HOP_SH=${HOP_SH:-/usr/local/lib/reality-menu/hy2-hop.sh}
OFFICIAL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
DEFAULT_SNI=addons.mozilla.org
# v26.7.28 是仍接受 Shadowrocket 的版本：v26.9.8 起 Reality 拒绝不含 X25519MLKEM768 的 ClientHello。
# v26.7.11–v26.9.7 在 minClientVer 为空时内置下限 26.3.27，需写成 1.0.0 才能放行 OpenClash / FlClash。
XRAY_PIN=v26.7.28
XRAY_MINCLIENT_FROM=26.7.11
XRAY_MLKEM_FROM=26.9.8
AUTO=${AUTO:-0}
if [ -n "${XRAY_VERSION+x}" ]; then XRAY_VERSION_SET=1; else XRAY_VERSION_SET=0; XRAY_VERSION=$XRAY_PIN; fi

warn() { printf '警告：%s\n' "$*" >&2; }

env_flag() {
  local name=$1 def=$2 val
  if [ -z "${!name+x}" ] || [ -z "${!name}" ]; then
    printf '%s\n' "$def"
    return 0
  fi
  val=$(printf '%s' "${!name}" | tr '[:upper:]' '[:lower:]')
  case "$val" in
    1|true|yes|y|on) printf '1\n' ;;
    0|false|no|n|off) printf '0\n' ;;
    *) printf '%s\n' "$def" ;;
  esac
}

valid_ip() {
  local ip=$1 o
  if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
      if [ "$((10#$o))" -gt 255 ]; then
        return 1
      fi
    done
    return 0
  fi
  if [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$ip" == *:*:* ]]; then
    return 0
  fi
  return 1
}

validate_port() {
  local p=$1
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

normalize_sni() {
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  s=${s#https://}
  s=${s#http://}
  s=${s%%/*}
  s=${s%:443}
  s=${s%.}
  printf '%s\n' "$s"
}

valid_sni() {
  local s=$1
  [[ "$s" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] || return 1
  [[ "$s" =~ ^[0-9.]+$ ]] && return 1
  return 0
}

confirm() {
  local ans
  read -r -p "$1 (y/N) " ans || return 1
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_flag() {
  local name=$1 def=$2 msg=$3 ans hint cur
  cur=$(env_flag "$name" "$def")
  if [ "$cur" = 1 ]; then hint="Y/n"; else hint="y/N"; fi
  read -r -p "${msg}？(${hint}) " ans || return 1
  if [ "$cur" = 1 ]; then
    case "$ans" in
      n|N|no|NO) printf -v "$name" '%s' 0 ;;
      *) printf -v "$name" '%s' 1 ;;
    esac
  else
    case "$ans" in
      y|Y|yes|YES) printf -v "$name" '%s' 1 ;;
      *) printf -v "$name" '%s' 0 ;;
    esac
  fi
  export "${name?}"
}

rand_int() {
  local a=$1 b=$2
  if command -v shuf >/dev/null 2>&1; then
    shuf -i "${a}-${b}" -n 1
    return 0
  fi
  python3 -c 'import random,sys; print(random.randint(int(sys.argv[1]), int(sys.argv[2])))' "$a" "$b"
}

parse_port_range() {
  local raw=$1 start end
  raw=${raw//:/-}
  if [[ ! "$raw" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    return 1
  fi
  start=${BASH_REMATCH[1]}
  end=${BASH_REMATCH[2]}
  if ! validate_port "$start" || ! validate_port "$end" || [ "$start" -ge "$end" ]; then
    return 1
  fi
  if [ "$start" -le 443 ] && [ "$end" -ge 443 ]; then
    return 2
  fi
  printf '%s %s\n' "$start" "$end"
}

systemd_booted() {
  [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}

linux_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    armv7l|armv6l) printf 'arm\n' ;;
    i386|i686) printf '386\n' ;;
    *) return 1 ;;
  esac
}

pkg_install() {
  if command -v apt-get >/dev/null 2>&1; then
    if [ "${PKG_UPDATED:-0}" != 1 ]; then
      apt-get update -qq || true
      PKG_UPDATED=1
    fi
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y "$@"
    return $?
  fi
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
    return $?
  fi
  if command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
    return $?
  fi
  return 1
}

need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  pkg_install "$1" >/dev/null 2>&1
}

ensure_epel() {
  command -v rpm >/dev/null 2>&1 || return 0
  rpm -q epel-release >/dev/null 2>&1 && return 0
  pkg_install epel-release || pkg_install oracle-epel-release-el9
}

download_bin() {
  local url=$1 dest=$2 tmp
  tmp=$(mktemp)
  if curl -fL --retry 3 --retry-delay 2 --max-time 180 -o "$tmp" "$url"; then
    chmod 755 "$tmp"
    mv "$tmp" "$dest"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

upsert_env() {
  local file=$1 key=$2 val=$3 tmp
  case "$val" in
    *$'\n'*) warn "环境值含换行，已忽略 ${key}"; return 1 ;;
  esac
  mkdir -p "$(dirname "$file")"
  tmp=$(mktemp)
  if [ -f "$file" ]; then
    grep -v "^${key}=" "$file" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
  chmod 600 "$file"
}

get_ip() {
  local ip=""
  ip=$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)
  if ! valid_ip "$ip"; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  if valid_ip "$ip"; then
    printf '%s\n' "$ip"
    return 0
  fi
  return 1
}

ipv4_slash24() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    addr = ipaddress.ip_address(sys.argv[1])
except ValueError:
    sys.exit(1)
if addr.version != 4:
    sys.exit(1)
print(ipaddress.ip_network("%s/24" % addr, strict=False))
PY
}

# --- Xray 版本（保持原有钉扎和 minClientVer 行为） ---

normalize_xray_version() {
  local raw low
  raw=$(printf '%s' "$1" | tr -d '[:space:]')
  low=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  if [ "$low" = latest ]; then
    printf '%s\n' latest
    return 0
  fi
  if [ -z "$raw" ]; then
    printf '%s\n' "$XRAY_PIN"
    return 0
  fi
  printf 'v%s\n' "${raw#[vV]}"
}

ver_ge() {
  local a="${1#[vV]}" b="${2#[vV]}"
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" = "$b" ]
}

version_needs_min_client() {
  local v
  [ "$1" = latest ] && return 1
  v="${1#[vV]}"
  ver_ge "$v" "$XRAY_MINCLIENT_FROM" || return 1
  ver_ge "$v" "$XRAY_MLKEM_FROM" && return 1
  return 0
}

version_breaks_shadowrocket() {
  [ "$1" = latest ] && return 0
  ver_ge "${1#[vV]}" "$XRAY_MLKEM_FROM"
}

xray_bin() {
  if [ -n "${XRAY_BIN:-}" ]; then
    if [ -x "$XRAY_BIN" ]; then
      printf '%s\n' "$XRAY_BIN"
      return 0
    fi
    return 1
  fi
  if [ -x /usr/local/bin/xray ]; then
    printf '%s\n' /usr/local/bin/xray
    return 0
  fi
  if command -v xray >/dev/null 2>&1; then
    command -v xray
    return 0
  fi
  return 1
}

xray_installed_version() {
  local line ver bin
  bin=$(xray_bin) || return 1
  line=$("$bin" version 2>/dev/null | head -n1 || true)
  if [ -z "$line" ]; then
    line=$("$bin" -version 2>/dev/null | head -n1 || true)
  fi
  [ -n "$line" ] || return 1
  ver=$(printf '%s\n' "$line" | awk '{print $2}')
  [ -n "$ver" ] || return 1
  printf 'v%s\n' "${ver#[vV]}"
}

resolve_xray_version() {
  local got
  got=$(xray_installed_version || true)
  if [ -n "$got" ]; then
    printf '%s\n' "$got"
  elif [ "$XRAY_CHOSEN" != latest ]; then
    printf '%s\n' "$XRAY_CHOSEN"
  fi
}

warn_shadowrocket() {
  printf '\n'
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo " 警告：此 Xray 版本与 Shadowrocket（小火箭）不兼容"
  echo " v${XRAY_MLKEM_FROM} 起 Reality 会拒绝 ClientHello 中不含 X25519MLKEM768 的客户端。"
  echo " Shadowrocket 2.2.92 不发送该密钥：延迟测试可以通过，实际连接会静默失败。"
  echo " 要同时兼容 Shadowrocket、OpenClash、FlClash，请安装固定版本 ${XRAY_PIN}。"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  printf '\n'
}

select_xray_version() {
  local ans
  if [ "$XRAY_VERSION_SET" = 1 ] || [ "$AUTO" = 1 ]; then
    XRAY_CHOSEN=$XRAY_VERSION
    return 0
  fi
  echo "Xray 默认固定 ${XRAY_PIN}：可同时兼容 Shadowrocket、OpenClash、FlClash。"
  echo "直接回车使用该版本；输入 latest 安装官方最新版；也可输入其它版本号，例如 v26.6.27。"
  echo "注意：v${XRAY_MLKEM_FROM} 及以上会拒绝不含 X25519MLKEM768 的 ClientHello，Shadowrocket 2.2.92 延迟测试能过但连接会静默失败。"
  read -r -p "Xray 版本 [${XRAY_PIN}]: " ans || return 1
  XRAY_CHOSEN=$(normalize_xray_version "${ans:-$XRAY_PIN}")
}

prepare_xray_install() {
  local a
  select_xray_version || return 1
  if version_breaks_shadowrocket "$XRAY_CHOSEN"; then
    warn_shadowrocket
    if [ "$AUTO" != 1 ] && [ "$XRAY_VERSION_SET" != 1 ]; then
      read -r -p "仍要安装该版本？(y/N) " a || return 1
      [ "$a" = y ] || [ "$a" = Y ] || { echo "已取消"; return 1; }
    fi
  elif version_needs_min_client "$XRAY_CHOSEN"; then
    echo "该版本在 minClientVer 为空时会拒绝 OpenClash / FlClash。安装后将把 Reality 的 minClientVer 设为 1.0.0。"
  fi
  echo "将安装 Xray ${XRAY_CHOSEN}"
}

install_xray() {
  local script
  need curl || return 1
  script=$(curl -fsSL "$OFFICIAL") || { echo "下载 Xray 安装脚本失败"; return 1; }
  if [ "$1" = latest ]; then
    bash -c "$script" @ install
  else
    bash -c "$script" @ install --version "$1"
  fi
}

xray_test() {
  local bin out
  bin=$(xray_bin) || { printf '%s\n' "找不到 xray，无法测试配置。" >&2; return 1; }
  if [ -z "${XRAY_LOCATION_ASSET:-}" ] && [ -d /usr/local/share/xray ]; then
    XRAY_LOCATION_ASSET=/usr/local/share/xray
    export XRAY_LOCATION_ASSET
  fi
  if [ -n "${XRAY_LOCATION_ASSET:-}" ]; then
    if ! out=$(XRAY_LOCATION_ASSET="$XRAY_LOCATION_ASSET" "$bin" run -test -config "$CONF" 2>&1); then
      printf '%s\n' "$out" >&2
      return 1
    fi
  elif ! out=$("$bin" run -test -config "$CONF" 2>&1); then
    printf '%s\n' "$out" >&2
    return 1
  fi
  return 0
}

make_backup() {
  local f=$1 bak
  [ -f "$f" ] || return 1
  bak="${f}.bak.$(date +%Y%m%d%H%M%S).$$"
  cp -a "$f" "$bak" || return 1
  printf '%s\n' "$bak"
}

prepare_xray_backup() {
  XRAY_BAK=""
  if [ -f "$CONF" ]; then
    XRAY_BAK=$(make_backup "$CONF") || return 1
  fi
  return 0
}

commit_xray_config() {
  if xray_test; then
    return 0
  fi
  printf '%s\n' "xray 配置测试失败，正在回滚。" >&2
  if [ -n "${XRAY_BAK:-}" ] && [ -f "$XRAY_BAK" ]; then
    cp -a "$XRAY_BAK" "$CONF" || return 1
  else
    rm -f "$CONF"
  fi
  return 1
}

config_blocks_cn() {
  local path=$1
  [ -f "$path" ] || return 1
  python3 - "$path" <<'PY'
import json, sys
try:
    cfg = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(1)
for rule in (cfg.get("routing") or {}).get("rules") or []:
    if "geosite:cn" in (rule.get("domain") or []) or "geoip:cn" in (rule.get("ip") or []):
        sys.exit(0)
sys.exit(1)
PY
}

write_xray_config() {
  local dest=$1 port=$2 sni=$3 uuid=$4 priv=$5 sid=$6 minclient=$7 block_cn=$8
  mkdir -p "$(dirname "$dest")"
  python3 - "$dest" "$port" "$sni" "$uuid" "$priv" "$sid" "$minclient" "$block_cn" <<'PY'
import json, os, sys
dest, port, sni, uuid, priv, sid, minclient, block_cn = sys.argv[1:9]
reality = {
    "dest": sni + ":443",
    "serverNames": [sni],
    "privateKey": priv,
    "shortIds": [sid],
}
if minclient == "1":
    reality["minClientVer"] = "1.0.0"
rules = [
    {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
    {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
]
if block_cn == "1":
    rules.append({"type": "field", "domain": ["geosite:cn"], "outboundTag": "block"})
    rules.append({"type": "field", "ip": ["geoip:cn"], "outboundTag": "block"})
cfg = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "listen": "0.0.0.0",
        "port": int(port),
        "protocol": "vless",
        "settings": {
            "clients": [{"id": uuid, "flow": "xtls-rprx-vision"}],
            "decryption": "none",
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": reality,
        },
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
    }],
    "outbounds": [
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "block"},
    ],
    "routing": {"domainStrategy": "IPIfNonMatch", "rules": rules},
}
tmp = dest + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.chmod(tmp, 0o644)
os.replace(tmp, dest)
PY
}

apply_min_client_ver() {
  [ -f "$CONF" ] || { echo "没有找到 $CONF，未写入 minClientVer"; return 1; }
  need python3 || { echo "python3 不可用，未能写入 minClientVer"; return 1; }
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

write_reality_link() {
  local ip=$1
  mkdir -p "$(dirname "$LINKF")"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#Reality-%s\n' \
    "$UUID" "$ip" "$PORT" "$SNI" "$PUB" "$SID" "$ip" > "$LINKF"
  chmod 600 "$LINKF"
}

refresh_reality_link() {
  local ip=""
  if [ -f "$LINKF" ]; then
    ip=$(sed -n 's#.*@\([0-9.]*\):.*#\1#p' "$LINKF" | head -n1)
  fi
  if ! valid_ip "$ip"; then
    ip=$(get_ip || true)
  fi
  if ! valid_ip "$ip"; then
    warn "无法刷新单节点链接。"
    return 1
  fi
  python3 - "$CONF" "$PUBF" "$LINKF" "$ip" <<'PY'
import json, os, re, sys
conf, pubf, linkf, ip = sys.argv[1:5]
cfg = json.load(open(conf, encoding="utf-8"))
pub = ""
try:
    pub = open(pubf, encoding="utf-8").read().strip()
except OSError:
    pub = ""
if not pub:
    try:
        old = open(linkf, encoding="utf-8").read()
    except OSError:
        old = ""
    m = re.search(r"pbk=([^&#\s]+)", old)
    pub = m.group(1) if m else ""
if not pub:
    sys.exit(1)
for ib in cfg.get("inbounds") or []:
    ss = ib.get("streamSettings") or {}
    if ib.get("protocol") != "vless" or ss.get("security") != "reality":
        continue
    rs = ss.get("realitySettings") or {}
    client = (ib.get("settings") or {}).get("clients") or [{}]
    uuid = client[0].get("id", "")
    flow = client[0].get("flow") or "xtls-rprx-vision"
    sni = (rs.get("serverNames") or [""])[0]
    sid = (rs.get("shortIds") or [""])[0]
    port = ib.get("port")
    link = "vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#Reality-%s\n" % (
        uuid, ip, port, flow, sni, pub, sid, ip)
    with open(linkf, "w", encoding="utf-8") as fh:
        fh.write(link)
    os.chmod(linkf, 0o600)
    sys.exit(0)
sys.exit(1)
PY
}

apply_dest_domain() {
  local domain=$1 work
  if [ ! -f "$CONF" ]; then
    echo "还没有 Xray 配置，请先安装 Reality。"
    return 1
  fi
  if ! valid_sni "$domain"; then
    echo "域名无效：$domain"
    return 1
  fi
  prepare_xray_backup || { echo "备份失败，未修改 dest。"; return 1; }
  work=$(mktemp)
  cp -a "$CONF" "$work" || { echo "复制配置失败"; return 1; }
  local rc=0
  python3 - "$work" "$domain" <<'PY'
import json, os, sys
path, domain = sys.argv[1], sys.argv[2]
cfg = json.load(open(path, encoding="utf-8"))
changed = False
for ib in cfg.get("inbounds") or []:
    ss = ib.get("streamSettings") or {}
    if ib.get("protocol") != "vless" or ss.get("security") != "reality":
        continue
    rs = ss.setdefault("realitySettings", {})
    rs["dest"] = domain + ":443"
    rs["serverNames"] = [domain]
    changed = True
if not changed:
    sys.exit(2)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.chmod(tmp, 0o644)
os.replace(tmp, path)
PY
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$work"
    if [ "$rc" -eq 2 ]; then
      echo "配置里没有 Reality 入站，未修改。"
    else
      echo "修改 dest 失败，配置保持原样。"
    fi
    return 1
  fi
  cp -a "$work" "$CONF"
  rm -f "$work"
  if ! commit_xray_config; then
    echo "新 dest 未通过 xray 测试，已恢复原配置。"
    return 1
  fi
  if ! refresh_reality_link; then
    warn "配置已切换，但单节点链接文件没有刷新。订阅仍会读取新配置。"
  fi
  if systemd_booted && [ "$(id -u)" -eq 0 ]; then
    if ! systemctl restart xray; then
      warn "配置测试已通过并已写入，但重启 Xray 失败。请看 journalctl -u xray。"
      return 1
    fi
  fi
  echo "已把 Reality dest / serverNames 切换为 ${domain}，并完成备份、测试和重启。"
}

# --- 订阅 ---

write_sub_server() {
  mkdir -p "$SUBDIR"
  chmod 700 "$SUBDIR"
  cat > "$SUBPY" <<'PYEOF'
#!/usr/bin/env python3
# 梯哥 Reality 通用订阅服务：按 User-Agent 返回 Clash Meta yaml 或 base64 vless 链接。
# 可选的 Hysteria2 节点从 REALITY_HYENV 读取，不改 Xray 入站。
import base64, json, os, re, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def load_env_file(path):
    env = {}
    try:
        fh = open(path, encoding="utf-8")
    except OSError:
        return env
    with fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k] = v
    return env

SUBENV_PATH = os.environ.get("REALITY_SUBENV", "/usr/local/etc/reality-sub/sub.env")
CONF = os.environ.get("REALITY_XRAY_CONF", "/usr/local/etc/xray/config.json")
PUBF = os.environ.get("REALITY_PUBF", "/usr/local/etc/xray/reality-pub.txt")
LINKF = os.environ.get("REALITY_LINKF", "/root/reality-link.txt")
HYENV = os.environ.get("REALITY_HYENV", "/etc/hysteria/reality-menu.env")
ENV = load_env_file(SUBENV_PATH)
CLASH_UA = re.compile(r"clash|mihomo|meta|stash|openclash|verge", re.I)

def pubkey():
    try:
        p = open(PUBF, encoding="utf-8").read().strip()
        if p:
            return p
    except OSError:
        pass
    try:
        text = open(LINKF, encoding="utf-8").read()
    except OSError:
        return ""
    m = re.search(r"pbk=([^&#\s]+)", text)
    return m.group(1) if m else ""

def reality_nodes():
    ip = ENV.get("IP", "")
    if not ip:
        return []
    try:
        c = json.load(open(CONF, encoding="utf-8"))
    except OSError:
        return []
    pbk = pubkey()
    out = []
    for ib in c.get("inbounds", []):
        ss = ib.get("streamSettings", {})
        if ib.get("protocol") != "vless" or ss.get("security") != "reality":
            continue
        r = ss["realitySettings"]
        sni = r["serverNames"][0]
        sid = (r.get("shortIds") or [""])[0]
        cl = ib["settings"]["clients"]
        for i, u in enumerate(cl):
            name = "Reality-%s-%s" % (ip, ib["port"]) + ("" if len(cl) == 1 else "-%d" % (i + 1))
            out.append(dict(name=name, ip=ip, port=ib["port"], uuid=u["id"], flow=u.get("flow", ""), sni=sni, pbk=pbk, sid=sid))
    return out

def hy2_node():
    env = load_env_file(HYENV)
    if not env.get("PORT") or not env.get("PASSWORD"):
        return None
    return env

def yaml_scalar(value):
    text = "" if value is None else str(value)
    if re.fullmatch(r"[A-Za-z0-9._-]+", text or ""):
        return text
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'

def v2ray(ns, hy):
    # 不写 support-x25519mlkem768。那是 mihomo 的 reality-opts，放进 vless:// 不能让 Shadowrocket 握手。
    links = []
    for n in ns:
        q = urllib.parse.urlencode(dict(encryption="none", flow=n["flow"], security="reality", sni=n["sni"], fp="chrome", pbk=n["pbk"], sid=n["sid"], type="tcp"))
        links.append("vless://%s@%s:%s?%s#%s" % (n["uuid"], n["ip"], n["port"], q, urllib.parse.quote(n["name"])))
    if hy:
        ip = hy.get("IP") or ENV.get("IP", "")
        port = hy.get("HOP") or hy["PORT"]
        auth = urllib.parse.quote(hy["PASSWORD"], safe="")
        q = {"insecure": "1"}
        if hy.get("SNI"):
            q["sni"] = hy["SNI"]
        if hy.get("PIN"):
            q["pinSHA256"] = hy["PIN"]
        name = urllib.parse.quote(hy.get("NAME") or ("Hy2-%s" % ip))
        links.append("hysteria2://%s@%s:%s?%s#%s" % (auth, ip, port, urllib.parse.urlencode(q), name))
    return base64.b64encode("\n".join(links).encode()).decode()

def clash(ns, hy):
    names = []
    y = ["mixed-port: 7890", "allow-lan: true", "mode: rule", "log-level: info", "proxies:"]
    for n in ns:
        names.append(n["name"])
        y += ['  - name: "%s"' % n["name"].replace('"', ""), "    type: vless", "    server: %s" % n["ip"], "    port: %s" % n["port"],
              "    uuid: %s" % n["uuid"], "    network: tcp", "    tls: true", "    udp: true"]
        if n["flow"]:
            y.append("    flow: %s" % n["flow"])
        y += ["    servername: %s" % n["sni"], "    client-fingerprint: chrome", "    reality-opts:",
              "      public-key: %s" % n["pbk"], '      short-id: "%s"' % n["sid"]]
    if hy:
        ip = hy.get("IP") or ENV.get("IP", "")
        name = hy.get("NAME") or ("Hy2-%s" % ip)
        names.append(name)
        y += ['  - name: "%s"' % name.replace('"', ""), "    type: hysteria2", "    server: %s" % yaml_scalar(ip),
              "    port: %s" % yaml_scalar(hy["PORT"]), "    password: %s" % yaml_scalar(hy["PASSWORD"])]
        if hy.get("HOP"):
            y.append("    ports: %s" % yaml_scalar(hy["HOP"]))
            y.append("    hop-interval: 30")
        if hy.get("SNI"):
            y.append("    sni: %s" % yaml_scalar(hy["SNI"]))
        y.append("    skip-cert-verify: true")
        if hy.get("PIN"):
            y.append("    fingerprint: %s" % yaml_scalar(hy["PIN"]))
    joined = ", ".join('"%s"' % n.replace('"', "") for n in names)
    y += ["proxy-groups:", '  - name: "PROXY"', "    type: select", '    proxies: ["AUTO", %s, DIRECT]' % joined,
          '  - name: "AUTO"', "    type: url-test", "    url: http://www.gstatic.com/generate_204", "    interval: 300",
          "    proxies: [%s]" % joined,
          "rules:", "  - DOMAIN-SUFFIX,local,DIRECT", "  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve", "  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
          "  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve", "  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve", "  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
          "  - GEOIP,LAN,DIRECT,no-resolve", "  - GEOIP,CN,DIRECT", "  - MATCH,PROXY"]
    return "\n".join(y) + "\n"

if os.environ.get("REALITY_PRINT_LINKS") == "1":
    text = base64.b64decode(v2ray(reality_nodes(), hy2_node())).decode()
    sys.stdout.write(text if text.endswith("\n") or not text else text + "\n")
    raise SystemExit(0)

class ReuseServer(ThreadingHTTPServer):
    allow_reuse_address = True

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        return
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        subpath = ENV.get("SUBPATH", "")
        if not subpath or u.path.rstrip("/") != "/" + subpath:
            self.send_response(404); self.end_headers(); return
        t = urllib.parse.parse_qs(u.query).get("target", [""])[0].lower()
        ua = self.headers.get("User-Agent", "")
        is_clash = t == "clash" or (t != "v2ray" and bool(CLASH_UA.search(ua)))
        try:
            body = (clash(reality_nodes(), hy2_node()) if is_clash else v2ray(reality_nodes(), hy2_node())).encode()
        except Exception:
            self.send_response(500); self.end_headers(); return
        self.send_response(200)
        self.send_header("Content-Type", "text/yaml; charset=utf-8" if is_clash else "text/plain; charset=utf-8")
        self.send_header("Content-Disposition", "attachment; filename*=UTF-8''%s" % ("Reality.yaml" if is_clash else "Reality.txt"))
        self.send_header("profile-update-interval", "24")
        self.send_header("Subscription-Userinfo", "upload=0; download=0; total=0; expire=0")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

bind = ENV.get("BIND") or "0.0.0.0"
ReuseServer((bind, int(ENV["SUBPORT"])), H).serve_forever()
PYEOF
  chmod 700 "$SUBPY"
  cat > "$SUBSVC" <<SVCEOF
[Unit]
Description=Reality subscription server
After=network.target
[Service]
ExecStart=/usr/bin/env python3 $SUBPY
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
SVCEOF
}

sub_url() {
  # shellcheck disable=SC1090
  . "$SUBENV"
  if [ "${TUNNEL:-0}" = 1 ] && [ -n "${TUNNEL_URL:-}" ]; then
    printf '%s/%s\n' "${TUNNEL_URL%/}" "$SUBPATH"
  else
    printf 'http://%s:%s/%s\n' "$IP" "$SUBPORT" "$SUBPATH"
  fi
}

sub_show() {
  # shellcheck disable=SC1090
  . "$SUBENV"
  local U
  U=$(sub_url)
  printf '\n'
  echo "=============================================================="
  echo " ★ 通用订阅链接（v2rayN / v2rayNG / 小火箭 / Clash Verge / OpenClash / NekoBox / Hiddify）"
  echo "   $U"
  echo "=============================================================="
  echo "强制 Clash 格式: $U?target=clash"
  echo "强制 V2Ray 格式: $U?target=v2ray"
  if [ "${TUNNEL:-0}" = 1 ] && [ -n "${TUNNEL_URL:-}" ]; then
    echo "订阅只监听 127.0.0.1，由 Cloudflare Quick Tunnel 提供 HTTPS。"
    echo "Quick Tunnel 域名在 reality-tunnel 重启后会变。打不开时重新选 8 查看新地址。"
  else
    echo "警告：订阅目前是 HTTP 明文。订阅地址等于节点密码，路径上任何人都能读到。这是默认方式，为了兼容旧客户端。"
    echo "若要只在本机监听并改用 HTTPS，安装时选择 Cloudflare Tunnel，或设置 SUB_TUNNEL=1。"
    echo "云服务商若有安全组，记得放行 ${SUBPORT}/TCP"
  fi
  need qrencode || true
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 "$U" || true
  fi
}

fw_ufw_active() {
  command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"
}

fw_firewalld_active() {
  command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1
}

fw_open_tcp() {
  local port=$1
  if fw_ufw_active; then
    ufw allow "${port}/tcp" >/dev/null || warn "ufw 放行 ${port}/tcp 失败"
  fi
  if fw_firewalld_active; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null || warn "firewalld 放行 ${port}/tcp 失败"
    firewall-cmd --reload >/dev/null || true
  fi
}

fw_close_tcp() {
  local port=$1
  if fw_ufw_active; then
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
  fi
  if fw_firewalld_active; then
    firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null || true
  fi
}

fw_open_udp_port() {
  local port=$1
  if fw_ufw_active; then
    ufw allow "${port}/udp" >/dev/null || warn "ufw 放行 ${port}/udp 失败"
  fi
  if fw_firewalld_active; then
    firewall-cmd --permanent --add-port="${port}/udp" >/dev/null || warn "firewalld 放行 ${port}/udp 失败"
    firewall-cmd --reload >/dev/null || true
  fi
}

fw_open_udp_range() {
  local start=$1 end=$2
  if fw_ufw_active; then
    ufw allow "${start}:${end}/udp" >/dev/null || warn "ufw 放行 UDP ${start}:${end} 失败"
  fi
  if fw_firewalld_active; then
    firewall-cmd --permanent --add-port="${start}-${end}/udp" >/dev/null || warn "firewalld 放行 UDP ${start}-${end} 失败"
    firewall-cmd --reload >/dev/null || true
  fi
}

stop_tunnel_service() {
  if [ -f /etc/systemd/system/reality-tunnel.service ] && systemd_booted; then
    systemctl disable --now reality-tunnel >/dev/null 2>&1 || true
  fi
}

start_cloudflare_tunnel() {
  local arch url port found=""
  # shellcheck disable=SC1090
  . "$SUBENV"
  port=$SUBPORT
  if ! systemd_booted; then
    warn "没有 systemd，不能常驻 cloudflared。"
    return 1
  fi
  arch=$(linux_arch) || { warn "认不出 CPU 架构，跳过 cloudflared。"; return 1; }
  if [ ! -x /usr/local/bin/cloudflared ]; then
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    if ! download_bin "$url" /usr/local/bin/cloudflared; then
      warn "下载 cloudflared 失败。"
      return 1
    fi
  fi
  if ! /usr/local/bin/cloudflared --version >/dev/null 2>&1; then
    warn "cloudflared 无法运行，已删除下载的文件。"
    rm -f /usr/local/bin/cloudflared
    return 1
  fi
  cat > /etc/systemd/system/reality-tunnel.service <<EOF
[Unit]
Description=Reality subscription Cloudflare quick tunnel
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:${port}
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || true
  local need_restart=1
  if systemctl is-active --quiet reality-tunnel; then
    if systemctl show reality-tunnel -p ExecStart --value 2>/dev/null | grep -q "127.0.0.1:${port}"; then
      need_restart=0
    fi
  fi
  systemctl enable reality-tunnel >/dev/null 2>&1 || true
  if [ "$need_restart" = 1 ]; then
    systemctl restart reality-tunnel || { warn "cloudflared 启动失败。"; return 1; }
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    found=$(journalctl -u reality-tunnel -n 120 -o cat --no-pager 2>/dev/null | grep -oE 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' | tail -n1 || true)
    if [ -n "$found" ]; then
      break
    fi
    sleep 1
  done
  if [ -z "$found" ]; then
    warn "没有从 cloudflared 日志里拿到 trycloudflare 地址。"
    journalctl -u reality-tunnel -n 40 --no-pager >&2 || true
    return 1
  fi
  upsert_env "$SUBENV" TUNNEL_URL "$found" || return 1
  echo "Cloudflare Quick Tunnel: ${found}"
  return 0
}

sub_enable() {
  local p sp spath ip want
  if [ ! -f "$CONF" ]; then
    echo "请先安装 Reality（选项 1）"
    return 1
  fi
  if [ ! -s "$PUBF" ]; then
    p=$(grep -o 'pbk=[^&#]*' "$LINKF" 2>/dev/null | head -n1 | cut -d= -f2 || true)
    if [ -z "$p" ]; then
      echo "找不到公钥（$PUBF 或 $LINKF），无法生成订阅"
      return 1
    fi
    printf '%s\n' "$p" > "$PUBF"
    chmod 600 "$PUBF"
  fi
  need python3 || { echo "python3 安装失败"; return 1; }
  mkdir -p "$SUBDIR"
  chmod 700 "$SUBDIR"
  if [ ! -f "$SUBENV" ]; then
    sp=$(rand_int 20000 60000)
    spath=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    ip=$(get_ip || true)
    if [ -z "$ip" ]; then
      echo "无法取得服务器 IP"
      return 1
    fi
    printf 'IP=%s\nSUBPORT=%s\nSUBPATH=%s\nBIND=0.0.0.0\nTUNNEL=0\nTUNNEL_URL=\n' "$ip" "$sp" "$spath" > "$SUBENV"
    chmod 600 "$SUBENV"
  fi
  if [ -n "${SUB_TUNNEL+x}" ] && [ -n "${SUB_TUNNEL}" ]; then
    want=$(env_flag SUB_TUNNEL 0)
  else
    want=$(awk -F= '$1=="TUNNEL"{print $2}' "$SUBENV" 2>/dev/null || true)
    [ "$want" = 1 ] || want=0
  fi
  if [ "$want" = 1 ]; then
    if start_cloudflare_tunnel; then
      upsert_env "$SUBENV" BIND 127.0.0.1
      upsert_env "$SUBENV" TUNNEL 1
      # shellcheck disable=SC1090
      . "$SUBENV"
      fw_close_tcp "$SUBPORT"
    else
      warn "Cloudflare Tunnel 没能启动，订阅保持 HTTP 明文。"
      upsert_env "$SUBENV" BIND 0.0.0.0
      upsert_env "$SUBENV" TUNNEL 0
      upsert_env "$SUBENV" TUNNEL_URL ""
      stop_tunnel_service
      # shellcheck disable=SC1090
      . "$SUBENV"
      fw_open_tcp "$SUBPORT"
    fi
  else
    stop_tunnel_service
    upsert_env "$SUBENV" BIND 0.0.0.0
    upsert_env "$SUBENV" TUNNEL 0
    upsert_env "$SUBENV" TUNNEL_URL ""
    # shellcheck disable=SC1090
    . "$SUBENV"
    fw_open_tcp "$SUBPORT"
  fi
  write_sub_server
  if systemd_booted; then
    systemctl daemon-reload || true
    systemctl enable reality-sub >/dev/null 2>&1 || true
    if ! systemctl restart reality-sub; then
      echo "订阅服务启动失败："
      journalctl -u reality-sub -n 20 --no-pager || true
      return 1
    fi
    sleep 1
    if ! systemctl is-active --quiet reality-sub; then
      echo "订阅服务启动失败："
      journalctl -u reality-sub -n 20 --no-pager || true
      return 1
    fi
  fi
  sub_show
}

sub_reset() {
  local keep_tunnel=0
  if [ ! -f "$SUBENV" ]; then
    echo "订阅未开启"
    return
  fi
  # shellcheck disable=SC1090
  . "$SUBENV"
  fw_close_tcp "$SUBPORT"
  keep_tunnel=${TUNNEL:-0}
  rm -f "$SUBENV"
  echo "已重置，旧订阅地址失效，请在客户端换成新地址"
  if [ "$keep_tunnel" = 1 ]; then
    SUB_TUNNEL=1 sub_enable
  else
    SUB_TUNNEL=0 sub_enable
  fi
}

sub_disable() {
  local port=""
  if systemd_booted; then
    systemctl disable --now reality-sub >/dev/null 2>&1 || true
    systemctl disable --now reality-tunnel >/dev/null 2>&1 || true
  fi
  if [ -f "$SUBENV" ]; then
    # shellcheck disable=SC1090
    . "$SUBENV"
    port=${SUBPORT:-}
  fi
  if [ -n "$port" ]; then
    fw_close_tcp "$port"
  fi
  rm -f "$SUBSVC" /etc/systemd/system/reality-tunnel.service
  if [ "$SUBDIR" = /usr/local/etc/reality-sub ]; then
    rm -rf "$SUBDIR"
  else
    rm -f "$SUBENV" "$SUBPY"
  fi
  if systemd_booted; then
    systemctl daemon-reload || true
  fi
  echo "订阅已关闭"
}

show_link() {
  if [ ! -f "$LINKF" ]; then
    echo "没有找到 $LINKF（可能不是用本脚本部署的）"
    return
  fi
  printf '\n'
  cat "$LINKF"
  printf '\n'
  need qrencode || true
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 "$(cat "$LINKF")" || true
  fi
  if [ -f "$HYLINK" ]; then
    echo "Hysteria2 备用链接："
    cat "$HYLINK"
    printf '\n'
  fi
  if [ -f "$SUBENV" ] && systemd_booted && systemctl is-active --quiet reality-sub; then
    sub_show
  elif [ -f "$SUBENV" ] && ! systemd_booted; then
    sub_show
  else
    echo "订阅未开启，可选 8 开启"
  fi
}

# --- fail2ban（检测发行版、SSH 单元、日志和防火墙；失败只跳过） ---

detect_ssh_unit() {
  local id=""
  command -v systemctl >/dev/null 2>&1 || return 1
  if systemctl cat ssh.service >/dev/null 2>&1; then
    id=$(systemctl show -p Id --value ssh.service 2>/dev/null || true)
  fi
  if [ -z "$id" ] && systemctl cat sshd.service >/dev/null 2>&1; then
    id=$(systemctl show -p Id --value sshd.service 2>/dev/null || true)
  fi
  case "$id" in
    ssh.service|sshd.service) printf '%s\n' "$id"; return 0 ;;
    *) return 1 ;;
  esac
}

read_sshd_ports() {
  sshd -T 2>/dev/null | awk 'tolower($1)=="port"{printf "%s%s", sep, $2; sep=","}'
}

detect_ssh_ports() {
  local ports="" item ok=1
  local -a found=()
  command -v sshd >/dev/null 2>&1 || return 1
  ports=$(read_sshd_ports)
  if [ -z "$ports" ] && [ ! -d /run/sshd ]; then
    mkdir -p /run/sshd 2>/dev/null || true
    chmod 755 /run/sshd 2>/dev/null || true
    if [ -d /run/sshd ]; then
      printf '%s\n' "sshd 还没有特权分离目录 /run/sshd，已补上后再读取端口。" >&2
      ports=$(read_sshd_ports)
    fi
  fi
  [ -n "$ports" ] || return 1
  IFS=',' read -r -a found <<< "$ports"
  for item in "${found[@]}"; do
    validate_port "$item" || ok=0
  done
  [ "$ok" = 1 ] || return 1
  printf '%s\n' "$ports"
}

journal_ready() {
  if [ "${REALITY_JOURNAL_OK:-}" = 1 ]; then
    return 0
  fi
  if [ "${REALITY_JOURNAL_OK:-}" = 0 ]; then
    return 1
  fi
  systemd_booted || return 1
  command -v journalctl >/dev/null 2>&1 || return 1
  journalctl -n 0 --no-pager >/dev/null 2>&1 || return 1
  python3 -c 'import systemd.journal' >/dev/null 2>&1
}

choose_ssh_log_backend() {
  local unit=$1 logfile=""
  if [ -n "${REALITY_LOG_DIR:-}" ]; then
    if [ -f "$REALITY_LOG_DIR/auth.log" ]; then
      logfile="$REALITY_LOG_DIR/auth.log"
    elif [ -f "$REALITY_LOG_DIR/secure" ]; then
      logfile="$REALITY_LOG_DIR/secure"
    fi
  elif [ -f /var/log/auth.log ]; then
    logfile=/var/log/auth.log
  elif [ -f /var/log/secure ]; then
    logfile=/var/log/secure
  fi
  if [ -z "$logfile" ]; then
    if journal_ready && [ -n "$unit" ]; then
      printf 'systemd\n'
      return 0
    fi
    return 1
  fi
  if [ ! -s "$logfile" ] && journal_ready && [ -n "$unit" ]; then
    printf 'systemd\n'
    return 0
  fi
  printf 'file:%s\n' "$logfile"
}

journalmatch_for() {
  printf '_SYSTEMD_UNIT=%s + _COMM=sshd + _COMM=sshd-session\n' "$1"
}

firewalld_active() {
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    return 0
  fi
  command -v systemctl >/dev/null 2>&1 || return 1
  [ "$(systemctl is-active firewalld 2>/dev/null || true)" = active ]
}

ufw_active() {
  command -v ufw >/dev/null 2>&1 || return 1
  ufw status 2>/dev/null | grep -q "Status: active"
}

banaction_supported() {
  local action=$1 base dir
  base=${action%%\[*}
  dir=${F2B_ACTION_DIR:-/etc/fail2ban/action.d}
  [ -f "${dir}/${base}.conf" ]
}

detect_banaction() {
  if firewalld_active; then
    if banaction_supported firewallcmd-rich-rules; then
      printf '%s\n' firewallcmd-rich-rules
      return 0
    fi
    return 1
  fi
  if ufw_active; then
    if banaction_supported ufw; then
      printf '%s\n' ufw
      return 0
    fi
  fi
  if command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
    if banaction_supported nftables; then
      printf '%s\n' nftables
      return 0
    fi
  fi
  if command -v iptables >/dev/null 2>&1 && banaction_supported iptables-multiport; then
    printf '%s\n' iptables-multiport
    return 0
  fi
  if command -v nft >/dev/null 2>&1 && banaction_supported nftables; then
    printf '%s\n' nftables
    return 0
  fi
  return 1
}

client_ssh_ip() {
  local raw ip
  raw=${SSH_CLIENT:-}
  if [ -z "$raw" ]; then
    raw=${SSH_CONNECTION:-}
  fi
  ip=${raw%% *}
  if [ -n "$ip" ] && valid_ip "$ip"; then
    printf '%s\n' "$ip"
    return 0
  fi
  return 1
}

build_ignoreip() {
  local ip
  printf '127.0.0.1/8 ::1'
  if ip=$(client_ssh_ip); then
    printf ' %s' "$ip"
  fi
  printf '\n'
}

render_fail2ban_jail() {
  local port=$1 backend=$2 logpath=$3 unit=$4 banaction=$5 ignoreip=$6
  printf '%s\n' "# Managed by reality-menu. Removing this file disables only this jail drop-in."
  printf '%s\n' "[sshd]"
  printf '%s\n' "enabled = true"
  printf '%s\n' "port = ${port}"
  printf '%s\n' "ignoreip = ${ignoreip}"
  printf '%s\n' "banaction = ${banaction}"
  printf '%s\n' "backend = ${backend}"
  if [ "$backend" = systemd ]; then
    printf 'journalmatch = %s\n' "$(journalmatch_for "$unit")"
  else
    printf 'logpath = %s\n' "$logpath"
  fi
}

setup_fail2ban() {
  local flag unit="" ports="" backend="" logfile="" action="" ignore ip jail_bak=""
  flag=$(env_flag FAIL2BAN 1)
  if [ "$flag" != 1 ]; then
    echo "已跳过 fail2ban（FAIL2BAN=${FAIL2BAN}）。"
    return 0
  fi
  echo "正在配置 fail2ban 的 sshd 监狱（检测 SSH 端口、日志和防火墙；FAIL2BAN=0 可跳过）。"
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
      ensure_epel || warn "EPEL 没装上，仍会尝试安装 fail2ban。"
    fi
    if ! pkg_install fail2ban; then
      warn "fail2ban 安装失败，已跳过，不影响 Reality。"
      return 0
    fi
  fi
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    warn "找不到 fail2ban-client，已跳过。"
    return 0
  fi
  if systemd_booted && ! python3 -c 'import systemd.journal' >/dev/null 2>&1; then
    pkg_install python3-systemd || warn "python3-systemd 未装上。没有 auth.log / secure 时会跳过 journal 后端。"
  fi
  unit=$(detect_ssh_unit || true)
  ports=$(detect_ssh_ports || true)
  if [ -z "$ports" ]; then
    warn "无法从 sshd -T 读到 SSH 端口，已跳过 fail2ban，避免封错端口。"
    return 0
  fi
  if ! backend=$(choose_ssh_log_backend "$unit"); then
    warn "无法确定 SSH 日志来源（journal 或 auth.log/secure），已跳过 fail2ban。"
    return 0
  fi
  if [ "$backend" = systemd ] && [ -z "$unit" ]; then
    warn "要用 systemd 后端，但没有检测到 ssh.service 或 sshd.service，已跳过 fail2ban。"
    return 0
  fi
  if [ "$backend" != systemd ]; then
    logfile=${backend#file:}
    backend=auto
  fi
  action=$(detect_banaction || true)
  if [ -z "$action" ] && ! firewalld_active; then
    pkg_install nftables >/dev/null 2>&1 || true
    action=$(detect_banaction || true)
  fi
  if [ -z "$action" ]; then
    if firewalld_active; then
      warn "firewalld 在运行，但没有可用的 firewallcmd banaction，已跳过 fail2ban，避免和 firewalld 冲突。"
    else
      warn "检测不到 nftables、iptables、ufw 或 firewalld 封禁动作，已跳过 fail2ban。"
    fi
    return 0
  fi
  ignore=$(build_ignoreip)
  if ip=$(client_ssh_ip); then
    echo "fail2ban 白名单：127.0.0.1/8、::1，以及当前 SSH 来源 ${ip}。"
  else
    echo "fail2ban 白名单：127.0.0.1/8 和 ::1。没有 SSH_CLIENT，多半是在本机控制台执行。"
  fi
  echo "fail2ban：端口 ${ports}，后端 ${backend}${logfile:+（${logfile}）}，单元 ${unit:-无}，封禁 ${action}。"
  mkdir -p "$(dirname "$F2B_JAIL")"
  if [ -f "$F2B_JAIL" ]; then
    jail_bak=$(make_backup "$F2B_JAIL") || { warn "无法备份已有 fail2ban 片段，已跳过。"; return 0; }
  fi
  if ! render_fail2ban_jail "$ports" "$backend" "$logfile" "$unit" "$action" "$ignore" > "$F2B_JAIL"; then
    warn "写入 fail2ban 片段失败，已跳过。"
    return 0
  fi
  if ! fail2ban-client -t >/tmp/reality-menu-f2b.txt 2>&1; then
    warn "fail2ban 配置测试失败，已撤回本次写入。"
    tail -n 40 /tmp/reality-menu-f2b.txt >&2 || true
    if [ -n "$jail_bak" ] && [ -f "$jail_bak" ]; then
      cp -a "$jail_bak" "$F2B_JAIL"
    else
      rm -f "$F2B_JAIL"
    fi
    return 0
  fi
  if systemd_booted; then
    systemctl enable fail2ban >/dev/null 2>&1 || warn "fail2ban 未能设为开机启动。"
    if ! systemctl restart fail2ban; then
      warn "fail2ban 重启失败。配置已通过 fail2ban-client -t，请稍后手动检查。不影响 Reality。"
      systemctl status fail2ban --no-pager >&2 || true
      return 0
    fi
    sleep 1
    if fail2ban-client status sshd >/dev/null 2>&1; then
      echo "fail2ban sshd 监狱已启用。"
    else
      warn "fail2ban 已启动，但 sshd 监狱状态读取失败。请执行 fail2ban-client status sshd。"
    fi
  else
    warn "没有 systemd，fail2ban 片段已写好，但没有帮你启动服务。"
  fi
  return 0
}

remove_fail2ban_jail() {
  if [ ! -f "$F2B_JAIL" ]; then
    return 0
  fi
  rm -f "$F2B_JAIL"
  if command -v fail2ban-client >/dev/null 2>&1; then
    fail2ban-client -t >/dev/null 2>&1 || warn "删除本脚本的 fail2ban 片段后，配置测试未通过。请检查 /etc/fail2ban。"
  fi
  if systemd_booted; then
    systemctl reload fail2ban >/dev/null 2>&1 || systemctl restart fail2ban >/dev/null 2>&1 || true
  fi
  echo "已删除本脚本的 fail2ban 片段。fail2ban 软件本身还在。"
}

# --- SSH 密码登录 ---

ssh_key_in_file() {
  local file=$1
  [ -f "$file" ] || return 1
  grep -Eq '(^|[[:space:]])(ssh-(rsa|dss|ed25519)|ecdsa-sha2-|sk-ssh-|sk-ecdsa-)' "$file"
}

has_authorized_key() {
  local passwd=${REALITY_PASSWD_FILE:-/etc/passwd} home file
  FOUND_SSH_KEY_FILE=""
  [ -f "$passwd" ] || return 1
  while IFS= read -r home; do
    if [ -z "$home" ] || [ ! -d "$home" ]; then
      continue
    fi
    for file in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
      if ssh_key_in_file "$file"; then
        FOUND_SSH_KEY_FILE=$file
        return 0
      fi
    done
  done < <(awk -F: '($6 != "") {print $6}' "$passwd")
  return 1
}

setup_ssh_password() {
  local flag pk eff unit drop bak
  flag=$(env_flag DISABLE_SSH_PASSWORD 0)
  if [ "$flag" != 1 ]; then
    return 0
  fi
  if ! command -v sshd >/dev/null 2>&1; then
    warn "未找到 sshd，跳过关闭密码登录。"
    return 0
  fi
  if ! has_authorized_key; then
    warn "没有找到含公钥的 authorized_keys。已拒绝关闭 SSH 密码登录，避免把你锁在外面。"
    return 0
  fi
  pk=$(sshd -T 2>/dev/null | awk 'tolower($1)=="pubkeyauthentication"{print tolower($2); exit}')
  if [ "$pk" = no ]; then
    warn "PubkeyAuthentication 为 no，拒绝关闭密码登录。"
    return 0
  fi
  if [ ! -f /etc/ssh/sshd_config ]; then
    warn "没有 /etc/ssh/sshd_config，已跳过。"
    return 0
  fi
  mkdir -p /etc/ssh/sshd_config.d /var/lib/reality-menu
  bak=$(make_backup /etc/ssh/sshd_config) || { warn "无法备份 sshd_config，已跳过。"; return 0; }
  cp -a "$bak" /var/lib/reality-menu/sshd_config.bak
  drop=/etc/ssh/sshd_config.d/00-reality-menu-password.conf
  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    local tmp
    tmp=$(mktemp)
    {
      printf '%s\n' 'Include /etc/ssh/sshd_config.d/*.conf'
      cat /etc/ssh/sshd_config
    } > "$tmp"
    cat "$tmp" > /etc/ssh/sshd_config
    rm -f "$tmp"
  fi
  sed -i -r 's/^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]/# reality-menu: &/' /etc/ssh/sshd_config
  cat > "$drop" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF
  if ! sshd -t >/tmp/reality-menu-sshd.txt 2>&1; then
    cat > "$drop" <<'EOF'
PasswordAuthentication no
ChallengeResponseAuthentication no
EOF
  fi
  if ! sshd -t >/tmp/reality-menu-sshd.txt 2>&1; then
    warn "sshd -t 未通过，已回滚，密码登录保持原样。"
    cat /tmp/reality-menu-sshd.txt >&2 || true
    cp -a /var/lib/reality-menu/sshd_config.bak /etc/ssh/sshd_config
    rm -f "$drop"
    return 0
  fi
  eff=$(sshd -T 2>/dev/null | awk 'tolower($1)=="passwordauthentication"{print tolower($2); exit}')
  if [ "$eff" != no ]; then
    warn "写入后密码登录仍是 ${eff:-未知}，已回滚。"
    cp -a /var/lib/reality-menu/sshd_config.bak /etc/ssh/sshd_config
    rm -f "$drop"
    return 0
  fi
  unit=$(detect_ssh_unit || true)
  if [ -n "$unit" ] && systemd_booted; then
    if ! systemctl reload "$unit"; then
      warn "sshd 测试已通过，但 reload ${unit} 失败。当前这条连接不会被断开。请手动检查后再开新会话。"
    fi
  else
    warn "sshd 测试已通过，但没有可 reload 的 ssh 服务。请手动重载后再依赖新配置。"
  fi
  echo "已关闭 SSH 密码登录。公钥文件：${FOUND_SSH_KEY_FILE}"
  echo "请另外开一个终端确认能登录，再关掉当前会话。"
}

restore_ssh_password() {
  local drop=/etc/ssh/sshd_config.d/00-reality-menu-password.conf changed=0 unit
  if [ -f "$drop" ]; then
    rm -f "$drop"
    changed=1
  fi
  if [ -f /etc/ssh/sshd_config ] && grep -q '# reality-menu: ' /etc/ssh/sshd_config; then
    sed -i -r 's/^# reality-menu: //' /etc/ssh/sshd_config
    changed=1
  fi
  [ "$changed" = 1 ] || return 0
  if ! command -v sshd >/dev/null 2>&1 || ! sshd -t >/dev/null 2>&1; then
    warn "恢复 SSH 配置后 sshd -t 失败。"
    if [ -f /var/lib/reality-menu/sshd_config.bak ]; then
      cp -a /var/lib/reality-menu/sshd_config.bak /etc/ssh/sshd_config
      warn "已从 /var/lib/reality-menu/sshd_config.bak 恢复。"
    fi
    return 0
  fi
  unit=$(detect_ssh_unit || true)
  if [ -n "$unit" ] && systemd_booted; then
    systemctl reload "$unit" || warn "SSH 限制已从文件去掉，但 reload 失败。"
  fi
  echo "已移除本脚本写入的 SSH 密码登录限制。"
}

# --- Hysteria2 备用节点 ---

hy_managed() {
  [ -f "$HYCONF" ] && grep -q 'reality-menu managed' "$HYCONF"
}

write_hop_helper() {
  mkdir -p "$(dirname "$HOP_SH")"
  cat > "$HOP_SH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ENV=/usr/local/lib/reality-menu/hy2-hop.env
if [ -n "${HOP_ENV_OVERRIDE:-}" ]; then
  ENV=$HOP_ENV_OVERRIDE
fi
[ -f "$ENV" ] || exit 0
# shellcheck disable=SC1090
. "$ENV"
: "${START:?}" "${END:?}" "${PORT:?}" "${MODE:?}"
del_ipt() {
  local bin=$1
  command -v "$bin" >/dev/null 2>&1 || return 0
  while "$bin" -t nat -C PREROUTING -p udp --dport "${START}:${END}" -m comment --comment reality-menu-hy2-hop -j REDIRECT --to-ports "$PORT" >/dev/null 2>&1; do
    "$bin" -t nat -D PREROUTING -p udp --dport "${START}:${END}" -m comment --comment reality-menu-hy2-hop -j REDIRECT --to-ports "$PORT"
  done
}
case "${1:-}" in
  add)
    if [ "$MODE" = nft ]; then
      nft delete table inet reality_hy2_hop >/dev/null 2>&1 || true
      nft add table inet reality_hy2_hop
      nft add chain inet reality_hy2_hop prerouting '{ type nat hook prerouting priority dstnat; policy accept; }'
      nft add rule inet reality_hy2_hop prerouting udp dport "${START}-${END}" redirect to :"${PORT}"
    else
      del_ipt iptables
      iptables -t nat -A PREROUTING -p udp --dport "${START}:${END}" -m comment --comment reality-menu-hy2-hop -j REDIRECT --to-ports "$PORT"
      if command -v ip6tables >/dev/null 2>&1; then
        del_ipt ip6tables
        ip6tables -t nat -A PREROUTING -p udp --dport "${START}:${END}" -m comment --comment reality-menu-hy2-hop -j REDIRECT --to-ports "$PORT" || true
      fi
    fi
    ;;
  del)
    if [ "$MODE" = nft ]; then
      nft delete table inet reality_hy2_hop >/dev/null 2>&1 || true
    else
      del_ipt iptables
      del_ipt ip6tables
    fi
    ;;
  *)
    printf '%s\n' "usage: $0 add|del" >&2
    exit 2
    ;;
esac
EOF
  # The helper defaults to the production env path. Tests and custom installs override it.
  if [ "$HOP_ENV" != /usr/local/lib/reality-menu/hy2-hop.env ]; then
    sed -i "s#^ENV=/usr/local/lib/reality-menu/hy2-hop.env#ENV=${HOP_ENV}#" "$HOP_SH"
  fi
  chmod 755 "$HOP_SH"
}

choose_hy2_port() {
  local p
  if [ -n "${HY2_PORT:-}" ]; then
    if validate_port "$HY2_PORT" && [ "$HY2_PORT" != 443 ]; then
      printf '%s\n' "$HY2_PORT"
      return 0
    fi
    warn "HY2_PORT=${HY2_PORT} 不能用（要 1-65535，且不能是 443），改为随机高位端口。"
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    p=$(rand_int 20000 59999)
    [ "$p" = 443 ] && continue
    if command -v ss >/dev/null 2>&1 && ss -H -uln 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${p}$"; then
      continue
    fi
    printf '%s\n' "$p"
    return 0
  done
  return 1
}

enable_hy2_hop() {
  local parsed="" rc=0 start end port=$1 mode=""
  local raw=${HY2_HOP_RANGE:-20000-50000}
  HY2_HOP_APPLIED=""
  parsed=$(parse_port_range "$raw") || rc=$?
  if [ "$rc" -eq 2 ]; then
    warn "端口跳跃范围 ${raw} 包含 443，已跳过跳跃。Hysteria2 仍使用单端口 ${port}。"
    return 1
  fi
  if [ "$rc" -ne 0 ] || [ -z "$parsed" ]; then
    warn "端口跳跃范围无效：${raw}。已跳过跳跃。"
    return 1
  fi
  read -r start end <<< "$parsed"
  write_hop_helper
  if command -v nft >/dev/null 2>&1; then
    mode=nft
  elif command -v iptables >/dev/null 2>&1; then
    mode=iptables
  else
    if ! pkg_install nftables; then
      warn "没有 nft 或 iptables，端口跳跃已跳过。"
      return 1
    fi
    if command -v nft >/dev/null 2>&1; then
      mode=nft
    elif command -v iptables >/dev/null 2>&1; then
      mode=iptables
    else
      warn "安装防火墙工具后仍无法做 DNAT，端口跳跃已跳过。"
      return 1
    fi
  fi
  mkdir -p "$(dirname "$HOP_ENV")"
  printf 'START=%s\nEND=%s\nPORT=%s\nMODE=%s\n' "$start" "$end" "$port" "$mode" > "$HOP_ENV"
  chmod 600 "$HOP_ENV"
  if ! "$HOP_SH" add; then
    warn "写入 DNAT 规则失败，端口跳跃已跳过。"
    "$HOP_SH" del >/dev/null 2>&1 || true
    rm -f "$HOP_ENV"
    return 1
  fi
  fw_open_udp_range "$start" "$end"
  if systemd_booted; then
    cat > /etc/systemd/system/reality-hy2-hop.service <<EOF
[Unit]
Description=Hysteria2 port hopping DNAT (reality-menu)
Before=hysteria-server.service
After=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${HOP_SH} add
ExecStop=${HOP_SH} del
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || true
    systemctl enable reality-hy2-hop >/dev/null 2>&1 || warn "端口跳跃服务没能设为开机启动，重启后需要再执行一次安装。"
  fi
  HY2_HOP_APPLIED="${start}-${end}"
  echo "Hysteria2 端口跳跃：UDP ${start}-${end} -> ${port}（${mode}）。"
  return 0
}

disable_hy2_hop() {
  if [ -x "$HOP_SH" ]; then
    "$HOP_SH" del >/dev/null 2>&1 || true
  fi
  rm -f "$HOP_ENV"
  if systemd_booted; then
    systemctl disable --now reality-hy2-hop >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/reality-hy2-hop.service
    systemctl daemon-reload || true
  fi
  HY2_HOP_APPLIED=""
}

write_hy_client_env() {
  local ip=$1 port=$2 pass=$3 sni=$4 pin=$5 hop=$6
  mkdir -p "$(dirname "$HYENV")"
  {
    printf 'IP=%s\n' "$ip"
    printf 'PORT=%s\n' "$port"
    printf 'PASSWORD=%s\n' "$pass"
    printf 'SNI=%s\n' "$sni"
    printf 'PIN=%s\n' "$pin"
    printf 'HOP=%s\n' "$hop"
    printf 'NAME=Hy2-%s\n' "$ip"
  } > "$HYENV"
  chmod 600 "$HYENV"
}

save_hy2_link() {
  local link
  if [ ! -f "$SUBPY" ]; then
    return 0
  fi
  link=$(REALITY_SUBENV="$SUBENV" REALITY_XRAY_CONF="$CONF" REALITY_PUBF="$PUBF" REALITY_LINKF="$LINKF" REALITY_HYENV="$HYENV" REALITY_PRINT_LINKS=1 python3 "$SUBPY" | grep '^hysteria2://' | head -n1 || true)
  if [ -z "$link" ]; then
    warn "没有生成 Hysteria2 链接。"
    return 1
  fi
  printf '%s\n' "$link" > "$HYLINK"
  chmod 600 "$HYLINK"
  echo "Hysteria2 链接："
  printf '%s\n' "$link"
}

install_hysteria_binary() {
  local arch url
  arch=$(linux_arch) || { warn "认不出 CPU 架构，跳过 Hysteria2。"; return 1; }
  if [ -x /usr/local/bin/hysteria ] && /usr/local/bin/hysteria version >/dev/null 2>&1; then
    return 0
  fi
  url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}"
  if ! download_bin "$url" /usr/local/bin/hysteria; then
    warn "下载 apernet/hysteria 失败，已跳过备用节点。"
    return 1
  fi
  if ! /usr/local/bin/hysteria version >/dev/null 2>&1; then
    warn "hysteria 二进制无法运行，已跳过。"
    rm -f /usr/local/bin/hysteria
    return 1
  fi
  return 0
}

write_hysteria_service() {
  cat > /etc/systemd/system/hysteria-server.service <<'EOF'
[Unit]
Description=Hysteria2 server (reality-menu)
After=network-online.target reality-hy2-hop.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
}

setup_hysteria() {
  local flag port pass sni pin hop="" ip crt key
  flag=$(env_flag HYSTERIA2 0)
  if [ "$flag" != 1 ]; then
    return 0
  fi
  echo "正在安装 Hysteria2 备用节点（不修改 Reality 入站）。"
  if ! install_hysteria_binary; then
    return 0
  fi
  if hy_managed && [ -f "$HYENV" ]; then
    echo "已有本脚本管理的 Hysteria2，不轮换密码和端口。"
    port=$(awk -F= '$1=="PORT"{print $2}' "$HYENV")
    if [ -n "${HY2_HOP+x}" ] && [ -n "${HY2_HOP}" ]; then
      if [ "$(env_flag HY2_HOP 0)" = 1 ]; then
        enable_hy2_hop "$port" || true
        hop=${HY2_HOP_APPLIED:-}
      else
        disable_hy2_hop
        hop=""
      fi
      upsert_env "$HYENV" HOP "$hop"
    else
      hop=$(awk -F= '$1=="HOP"{print $2}' "$HYENV")
    fi
    if systemd_booted; then
      write_hysteria_service
      systemctl daemon-reload || true
      systemctl enable hysteria-server >/dev/null 2>&1 || true
      systemctl restart hysteria-server || warn "Hysteria2 重启失败。Reality 不受影响。"
    fi
    save_hy2_link || true
    return 0
  fi
  if [ -f "$HYCONF" ] && ! hy_managed; then
    warn "/etc/hysteria/config.yaml 已存在且不是本脚本写的，已跳过，避免覆盖。"
    return 0
  fi
  port=$(choose_hy2_port) || { warn "选不到可用 UDP 端口，已跳过 Hysteria2。"; return 0; }
  pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  sni=$SNI
  valid_sni "$sni" || sni=$DEFAULT_SNI
  mkdir -p /etc/hysteria
  chmod 700 /etc/hysteria
  crt=/etc/hysteria/server.crt
  key=/etc/hysteria/server.key
  if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$key" -out "$crt" -days 3650 -nodes \
      -subj "/CN=${sni}" \
      -addext "subjectAltName=DNS:${sni}" >/dev/null 2>&1 \
    && ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$key" -out "$crt" -days 3650 -nodes \
      -subj "/CN=${sni}" >/dev/null 2>&1; then
    warn "生成 Hysteria2 自签证书失败，已跳过。"
    return 0
  fi
  chmod 600 "$key"
  chmod 644 "$crt"
  pin=$(openssl x509 -in "$crt" -noout -fingerprint -sha256 | awk -F= '{print $2}')
  cat > "$HYCONF" <<EOF
# reality-menu managed
listen: 0.0.0.0:${port}

tls:
  cert: ${crt}
  key: ${key}

auth:
  type: password
  password: ${pass}

masquerade:
  type: proxy
  proxy:
    url: https://${sni}
    rewriteHost: true
EOF
  chmod 600 "$HYCONF"
  hop=""
  HY2_HOP_APPLIED=""
  if [ "$(env_flag HY2_HOP 0)" = 1 ]; then
    enable_hy2_hop "$port" || true
    hop=${HY2_HOP_APPLIED:-}
  fi
  fw_open_udp_port "$port"
  ip=${REALITY_CACHED_IP:-}
  if [ -z "$ip" ]; then
    ip=$(get_ip || true)
  fi
  if [ -z "$ip" ] && [ -f "$SUBENV" ]; then
    ip=$(awk -F= '$1=="IP"{print $2}' "$SUBENV")
  fi
  if [ -z "$ip" ]; then
    warn "拿不到公网 IP，Hysteria2 服务仍会安装，但链接里没有地址。"
    ip=127.0.0.1
  fi
  write_hy_client_env "$ip" "$port" "$pass" "$sni" "$pin" "$hop"
  if systemd_booted; then
    write_hysteria_service
    systemctl daemon-reload || true
    systemctl enable hysteria-server >/dev/null 2>&1 || true
    if ! systemctl restart hysteria-server; then
      warn "Hysteria2 启动失败。Reality 不受影响。journalctl -u hysteria-server"
      return 0
    fi
  else
    warn "没有 systemd，Hysteria2 配置已写好，但没有帮你拉起服务。"
  fi
  echo "Hysteria2 UDP ${port}，伪装 https://${sni}。没有占用 TCP 443，也没有改 Reality。"
  echo "云服务商安全组请放行 UDP ${port}${hop:+ 以及 ${hop}}。"
  save_hy2_link || true
}

remove_managed_hysteria() {
  hy_managed || return 0
  disable_hy2_hop
  if systemd_booted; then
    systemctl disable --now hysteria-server >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/hysteria-server.service
    systemctl daemon-reload || true
  fi
  rm -rf /etc/hysteria
  rm -f /usr/local/bin/hysteria "$HYLINK"
  echo "已删除本脚本安装的 Hysteria2。"
}

# --- 安装参数 ---

collect_options() {
  local ans def_sni cur_cn=0 cur_hop=0 cur_tunnel=0
  if config_blocks_cn "$CONF"; then
    cur_cn=1
  fi
  if [ -f "$HOP_ENV" ]; then
    cur_hop=1
  fi
  if [ -f "$SUBENV" ] && grep -q '^TUNNEL=1$' "$SUBENV"; then
    cur_tunnel=1
  fi
  if [ "$AUTO" = 1 ]; then
    PORT=${PORT:-443}
    SNI=$(normalize_sni "${SNI:-$DEFAULT_SNI}")
    if [ -z "${BLOCK_CN+x}" ] || [ -z "${BLOCK_CN}" ]; then
      BLOCK_CN=$cur_cn
    fi
  else
    while true; do
      read -r -p "端口 [443]: " ans || return 1
      PORT=${ans:-443}
      if validate_port "$PORT"; then
        break
      fi
      echo "端口要在 1-65535 之间。"
    done
    def_sni=$(normalize_sni "${SNI:-$DEFAULT_SNI}")
    while true; do
      read -r -p "伪装域名 dest/serverNames [${def_sni}]: " ans || return 1
      SNI=$(normalize_sni "${ans:-$def_sni}")
      if valid_sni "$SNI"; then
        break
      fi
      echo "请输入域名，例如 ${DEFAULT_SNI}。不要写 IP，也不要写路径。"
    done
    prompt_flag HYSTERIA2 0 "是否安装 Hysteria2 备用节点（独立高位 UDP，不改动 Reality）" || return 1
    if [ "$(env_flag HYSTERIA2 0)" = 1 ]; then
      prompt_flag HY2_HOP "$cur_hop" "是否为 Hysteria2 做端口跳跃（nftables/iptables 把一段 UDP 转到监听端口）" || return 1
    fi
    prompt_flag DISABLE_SSH_PASSWORD 0 "是否关闭 SSH 密码登录（必须已经有公钥，否则会拒绝并保持原样）" || return 1
    prompt_flag SUB_TUNNEL "$cur_tunnel" "订阅是否只监听 127.0.0.1，并用 Cloudflare Quick Tunnel 提供 HTTPS（默认否，继续用明文 HTTP）" || return 1
    echo "屏蔽中国大陆地址后，经本节点将无法打开国内网站（geoip:cn / geosite:cn 进入黑洞）。客户端自己的国内直连规则不受影响。"
    prompt_flag BLOCK_CN "$cur_cn" "是否屏蔽 geoip:cn / geosite:cn" || return 1
  fi
  if ! validate_port "$PORT"; then
    echo "端口无效：$PORT"
    return 1
  fi
  if ! valid_sni "$SNI"; then
    echo "伪装域名无效：$SNI（默认是 ${DEFAULT_SNI}）"
    return 1
  fi
}

enable_bbr() {
  if [ -f /etc/sysctl.conf ] && grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf; then
    sysctl -p >/dev/null 2>&1 || true
    return 0
  fi
  mkdir -p /etc
  touch /etc/sysctl.conf
  if ! grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf; then
    printf '%s\n' "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    printf '%s\n' "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  fi
  sysctl -p >/dev/null 2>&1 || true
}

deploy() {
  local installed minflag=0 ip
  collect_options || return 1
  if [ -f "$CONF" ] && [ "$AUTO" != 1 ]; then
    confirm "已有配置，继续会生成新密钥、旧链接失效" || return 0
  fi
  prepare_xray_install || return 1
  need curl || { echo "curl 安装失败"; return 1; }
  need openssl || { echo "openssl 安装失败"; return 1; }
  need python3 || { echo "python3 安装失败"; return 1; }
  install_xray "$XRAY_CHOSEN" || { echo "安装失败"; return 1; }
  hash -r || true
  installed=$(resolve_xray_version || true)
  if [ -n "$installed" ] && version_needs_min_client "$installed"; then
    minflag=1
    echo "当前 Xray：${installed}，将写入 minClientVer 1.0.0"
  elif [ -n "$installed" ]; then
    echo "当前 Xray：${installed}"
  else
    echo "无法读取已安装的 Xray 版本，未写入 minClientVer。若 OpenClash / FlClash 被拒绝，请在 realitySettings 中加入 \"minClientVer\": \"1.0.0\" 后重启 Xray。"
  fi
  local bin keys
  bin=$(xray_bin) || { echo "安装后仍找不到 xray"; return 1; }
  UUID=$("$bin" uuid) || { echo "生成 UUID 失败"; return 1; }
  keys=$("$bin" x25519) || { echo "生成 Reality 密钥失败"; return 1; }
  PRIV=$(printf '%s\n' "$keys" | awk -F': ' '/Private/{print $2; exit}')
  PUB=$(printf '%s\n' "$keys" | awk -F': ' '/Public|Password/{print $2; exit}')
  if [ -z "$PRIV" ] || [ -z "$PUB" ]; then
    echo "解析 xray x25519 输出失败"
    printf '%s\n' "$keys" >&2
    return 1
  fi
  SID=$(openssl rand -hex 8)
  prepare_xray_backup || { echo "备份旧配置失败，已中止，未改配置。"; return 1; }
  if ! write_xray_config "$CONF" "$PORT" "$SNI" "$UUID" "$PRIV" "$SID" "$minflag" "$(env_flag BLOCK_CN 0)"; then
    echo "写入 Xray 配置失败。"
    if [ -n "${XRAY_BAK:-}" ] && [ -f "$XRAY_BAK" ]; then
      cp -a "$XRAY_BAK" "$CONF" || true
    fi
    return 1
  fi
  if ! commit_xray_config; then
    return 1
  fi
  enable_bbr
  fw_open_tcp "$PORT"
  if systemd_booted; then
    systemctl enable xray >/dev/null 2>&1 || true
    systemctl restart xray || true
    sleep 1
    if ! systemctl is-active --quiet xray; then
      echo "Xray 启动失败："
      journalctl -u xray -n 30 --no-pager || true
      setup_fail2ban || true
      return 1
    fi
  fi
  ip=$(get_ip || true)
  if [ -z "$ip" ]; then
    echo "无法取得服务器 IP"
    return 1
  fi
  REALITY_CACHED_IP=$ip
  write_reality_link "$ip"
  printf '%s\n' "$PUB" > "$PUBF"
  chmod 600 "$PUBF"
  echo
  echo "== 部署完成，正在开启通用订阅 =="
  sub_enable || warn "订阅没有启动成功。Xray 本身已按测试通过的配置运行。可稍后选 8 重试。"
  setup_fail2ban || true
  setup_hysteria || true
  setup_ssh_password || true
  echo
  echo "== 单节点链接（备用，可直接导入，指纹 chrome，不含 mlkem）=="
  cat "$LINKF"
  echo "Reality：TCP ${PORT}，dest ${SNI}:443，flow xtls-rprx-vision。"
  if [ "$(env_flag BLOCK_CN 0)" = 1 ]; then
    echo "已屏蔽 geoip:cn / geosite:cn。经本节点访问国内网站会失败。"
  fi
  echo "云服务商若有安全组，记得放行 ${PORT}/TCP"
}

restart_xray() {
  if [ ! -f "$CONF" ]; then
    echo "没有配置，未重启"
    return 1
  fi
  if ! xray_test; then
    echo "配置测试未通过，未重启。"
    return 1
  fi
  if ! systemd_booted; then
    echo "没有 systemd，未重启。"
    return 1
  fi
  systemctl restart xray && echo "已重启"
}

update_xray() {
  local installed bak=""
  prepare_xray_install || return
  install_xray "$XRAY_CHOSEN" || { echo "更新失败"; return; }
  hash -r || true
  installed=$(resolve_xray_version || true)
  if [ -n "$installed" ]; then
    echo "当前 Xray：${installed}"
  else
    echo "无法读取已安装的 Xray 版本，未修改 minClientVer。"
  fi
  if [ -f "$CONF" ]; then
    bak=$(make_backup "$CONF") || { echo "备份失败，未修改配置，也未重启。"; return; }
    XRAY_BAK=$bak
    if [ -n "$installed" ] && version_needs_min_client "$installed"; then
      if ! apply_min_client_ver; then
        echo "写入 minClientVer 失败，已回滚，未重启。"
        cp -a "$bak" "$CONF" || true
        return
      fi
    fi
    if ! xray_test; then
      echo "配置测试未通过，已回滚，未重启。"
      cp -a "$bak" "$CONF" || true
      return
    fi
  fi
  if systemd_booted; then
    systemctl restart xray && echo "已重启"
  else
    echo "配置测试通过。没有 systemd，未重启服务。"
  fi
}

# --- RealiTLScanner ---

list_scan_candidates() {
  python3 - "$1" <<'PY'
import csv, os, re, ssl, sys, urllib.error, urllib.request
path = sys.argv[1]
host_re = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$")
redirect_codes = {301, 302, 303, 307, 308}
overrides = {}
mapped = os.environ.get("REALITY_REDIRECT_MAP", "")
if mapped:
    for line in open(mapped, encoding="utf-8"):
        parts = line.split()
        if len(parts) >= 2:
            overrides[parts[0].lower()] = int(parts[1])

def status_for(domain):
    if domain.lower() in overrides:
        return overrides[domain.lower()]
    ctx = ssl._create_unverified_context()
    class NoRedir(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    opener = urllib.request.build_opener(NoRedir, urllib.request.HTTPSHandler(context=ctx))
    try:
        with opener.open("https://%s/" % domain, timeout=8) as resp:
            return getattr(resp, "status", 200)
    except urllib.error.HTTPError as exc:
        return exc.code
    except Exception:
        return 0

seen = []
skipped_wild = skipped_redir = skipped_down = skipped_other = 0
with open(path, newline="", encoding="utf-8", errors="replace") as fh:
    reader = csv.reader(fh)
    header = next(reader, None)
    if not header:
        sys.exit(0)
    try:
        i_tls = header.index("TLS")
        i_alpn = header.index("ALPN")
        i_dom = header.index("CERT_DOMAIN")
    except ValueError:
        i_tls, i_alpn, i_dom = 2, 3, 8
    for row in reader:
        if len(row) <= i_dom:
            continue
        tls = row[i_tls].strip()
        alpn = row[i_alpn].strip()
        domain = row[i_dom].strip().strip('"').lower().rstrip(".")
        if tls not in ("TLS 1.3", "TLS1.3", "1.3") or alpn != "h2":
            skipped_other += 1
            continue
        if not domain or domain.startswith("*") or not host_re.match(domain) or re.fullmatch(r"[0-9.]+", domain):
            skipped_wild += 1
            continue
        if domain in seen:
            continue
        code = status_for(domain)
        if code in redirect_codes:
            skipped_redir += 1
            continue
        if code == 0:
            skipped_down += 1
            continue
        seen.append(domain)
print("候选筛选：保留 %d，跳过通配符/非法 %d，跳转 %d，连不上 %d，非 TLS1.3+h2 %d" % (
    len(seen), skipped_wild, skipped_redir, skipped_down, skipped_other), file=sys.stderr)
for domain in seen:
    print(domain)
PY
}

scan_dest_menu() {
  local ip cidr ans prefix bin arch out choice domain idx
  echo "这个扫描会连到网段里其它主机的 443，用来找 Reality 可用的 dest。"
  echo "条件：TLS 1.3、ALPN h2、证书域名不是通配符，并且 HTTPS 不返回跳转。"
  echo "警告：可能要很久。/24 通常是几分钟，更大的网段会久得多。"
  ip=$(get_ip || true)
  cidr=""
  if valid_ip "$ip"; then
    cidr=$(ipv4_slash24 "$ip" || true)
  fi
  if [ -n "$cidr" ]; then
    read -r -p "扫描范围 [${cidr}]（必须是 CIDR，单个 IP 会让扫描器停不下来）: " ans || return
  else
    read -r -p "扫描范围（CIDR，例如 1.2.3.0/24）: " ans || return
  fi
  ans=${ans:-$cidr}
  if [ -z "$ans" ]; then
    echo "没有扫描范围。"
    return
  fi
  if ! cidr=$(python3 - "$ans" <<'PY'
import ipaddress, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
except Exception:
    sys.exit(1)
if net.version != 4 or net.prefixlen >= 32:
    sys.exit(2)
print(net)
print(net.prefixlen)
PY
  ); then
    echo "请输入 IPv4 CIDR，例如 1.2.3.0/24。不要输入单个 IP 或域名，否则 RealiTLScanner 会进入无限扫描。"
    return
  fi
  prefix=$(printf '%s\n' "$cidr" | tail -n1)
  cidr=$(printf '%s\n' "$cidr" | head -n1)
  if [ "$prefix" -lt 24 ]; then
    confirm "网段 ${cidr} 大于 /24，可能非常久" || return
  else
    confirm "即将扫描 ${cidr}。这会花一些时间" || return
  fi
  arch=$(linux_arch || true)
  case "$arch" in
    amd64|arm64) ;;
    *) warn "RealiTLScanner 官方发布包只有 linux amd64/arm64，当前架构 ${arch:-未知}，无法扫描。"; return ;;
  esac
  mkdir -p "$(dirname "$SCANNER")"
  if [ ! -x "$SCANNER" ]; then
    echo "正在下载 XTLS/RealiTLScanner ..."
    if ! download_bin "https://github.com/XTLS/RealiTLScanner/releases/latest/download/RealiTLScanner-linux-${arch}" "$SCANNER"; then
      warn "下载 RealiTLScanner 失败。"
      return
    fi
  fi
  bin=$SCANNER
  out=/root/reality-scan.csv
  if ! touch "$out" 2>/dev/null; then
    out=$(mktemp /tmp/reality-scan.XXXXXX.csv)
  fi
  echo "开始扫描 ${cidr}，输出到 ${out}"
  if ! "$bin" -addr "$cidr" -port 443 -thread 32 -timeout 5 -out "$out"; then
    warn "扫描进程退出异常。若 csv 里已有结果，下面仍会尝试整理。"
  fi
  if [ ! -s "$out" ]; then
    echo "没有扫描结果。"
    return
  fi
  CANDS=()
  while IFS= read -r domain; do
    [ -n "$domain" ] && CANDS+=("$domain")
  done < <(list_scan_candidates "$out")
  if [ "${#CANDS[@]}" -eq 0 ]; then
    echo "没有同时满足 TLS1.3、h2、且不跳转的域名。原始结果在 ${out}"
    return
  fi
  echo "可选伪装域名："
  idx=1
  for domain in "${CANDS[@]}"; do
    printf '  %d) %s\n' "$idx" "$domain"
    idx=$((idx + 1))
  done
  read -r -p "输入序号切换 dest/serverNames，直接回车保持不变: " choice || return
  [ -n "$choice" ] || { echo "未修改 dest。"; return; }
  domain=""
  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    idx=$((choice - 1))
    if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#CANDS[@]}" ]; then
      domain=${CANDS[$idx]}
    fi
  else
    for domain in "${CANDS[@]}"; do
      if [ "$domain" = "$choice" ]; then
        break
      fi
      domain=""
    done
  fi
  if [ -z "$domain" ]; then
    echo "没有这个候选，配置未改。"
    return
  fi
  apply_dest_domain "$domain"
}

uninstall_all() {
  local script
  confirm "确定卸载并删除配置" || return
  script=$(curl -fsSL "$OFFICIAL" || true)
  if [ -n "$script" ]; then
    bash -c "$script" @ remove --purge || warn "Xray 官方卸载脚本失败，继续清理本脚本添加的内容。"
  else
    warn "下载 Xray 卸载脚本失败。"
  fi
  sub_disable || true
  remove_managed_hysteria || true
  remove_fail2ban_jail || true
  restore_ssh_password || true
  rm -f "$LINKF" "$PUBF" "$HYLINK"
  echo "卸载步骤已执行。fail2ban 软件包和 RealiTLScanner 二进制还留着。"
}

menu_loop() {
  local c
  while true; do
    printf '\n'
    echo "====== 梯哥 Reality 管理 ======"
    echo " 1. 安装 / 重装（默认 Xray ${XRAY_PIN}，dest ${DEFAULT_SNI}，自动开启订阅）"
    echo " 2. 查看导入链接和二维码"
    echo " 3. 查看运行状态"
    echo " 4. 查看最近日志"
    echo " 5. 重启服务"
    echo " 6. 更新 Xray（默认 ${XRAY_PIN}，可选最新版）"
    echo " 7. 卸载（含订阅服务）"
    echo " 8. 开启 / 查看订阅（通用订阅链接）"
    echo " 9. 重置订阅地址"
    echo "10. 关闭订阅"
    echo "11. 扫描本机网段，挑选 Reality 伪装域名（RealiTLScanner）"
    echo " 0. 退出"
    read -r -p "请选择: " c || exit 0
    case $c in
      1) deploy || true ;;
      2) show_link || true ;;
      3) systemctl status xray --no-pager || true ;;
      4) journalctl -u xray -n 50 --no-pager || true ;;
      5) restart_xray || true ;;
      6) update_xray || true ;;
      7) uninstall_all || true ;;
      8) sub_enable || true ;;
      9) sub_reset || true ;;
      10) sub_disable || true ;;
      11) scan_dest_menu || true ;;
      0) exit 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

main() {
  [ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
  if [ "$XRAY_VERSION_SET" = 1 ]; then
    XRAY_VERSION=$(normalize_xray_version "$XRAY_VERSION")
  fi
  if [ "${1:-}" = install ]; then
    AUTO=1
    deploy
    if systemd_booted; then
      if systemctl is-active --quiet xray; then
        exit 0
      fi
      exit 1
    fi
    if [ -f "$CONF" ] && xray_test >/dev/null 2>&1; then
      exit 0
    fi
    exit 1
  fi
  menu_loop
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
