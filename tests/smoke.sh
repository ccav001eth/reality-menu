#!/usr/bin/env bash
# 不需要 root。覆盖版本判断、配置生成、回滚、fail2ban 检测和订阅内容。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
unset XRAY_VERSION || true
# shellcheck disable=SC1091
source "$ROOT/reality-menu.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok %s\n' "$*"; }

[ "$(normalize_xray_version latest)" = latest ] || fail normalize-latest
[ "$(normalize_xray_version V26.7.28)" = v26.7.28 ] || fail normalize-v
[ "$(normalize_xray_version '')" = v26.7.28 ] || fail normalize-empty
ver_ge 26.7.28 26.7.11 || fail ver-ge
ver_ge 26.7.10 26.7.11 && fail ver-lt
version_needs_min_client v26.7.28 || fail needs-min
version_needs_min_client v26.7.10 && fail no-min-old
version_needs_min_client v26.9.8 && fail no-min-mlkem
version_needs_min_client latest && fail no-min-latest
version_breaks_shadowrocket latest || fail breaks-latest
version_breaks_shadowrocket v26.9.8 || fail breaks-mlkem
version_breaks_shadowrocket v26.7.28 && fail pin-breaks
ok version

[ "$(normalize_sni 'HTTPS://Addons.Mozilla.org/path')" = addons.mozilla.org ] || fail sni-norm
[ "$(normalize_sni 'addons.mozilla.org:443')" = addons.mozilla.org ] || fail sni-port
valid_sni addons.mozilla.org || fail sni-valid
valid_sni 1.2.3.4 && fail sni-ip
valid_sni notld && fail sni-single
[ "$(env_flag FAIL2BAN 1)" = 1 ]
FAIL2BAN=off
[ "$FAIL2BAN" = off ]
[ "$(env_flag FAIL2BAN 1)" = 0 ]
unset FAIL2BAN
HYSTERIA2=yes
[ "$HYSTERIA2" = yes ]
[ "$(env_flag HYSTERIA2 0)" = 1 ]
unset HYSTERIA2
valid_ip 203.0.113.10 || fail ip4
valid_ip 999.1.1.1 && fail ip4-bad
valid_ip '2001:db8::1' || fail ip6
SSH_CLIENT='203.0.113.10 50000 22'
[ "$(build_ignoreip)" = '127.0.0.1/8 ::1 203.0.113.10' ] || fail ignore
unset SSH_CLIENT
[ "$(build_ignoreip)" = '127.0.0.1/8 ::1' ] || fail ignore-local
ok flags

parse_port_range '20000-50000' >/dev/null || fail range
parse_port_range '1000:2000' >/dev/null || fail range-colon
if parse_port_range '400-500'; then fail range-includes-443; fi
rc=0
parse_port_range '400-500' >/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail range-443-code
rc=0
parse_port_range 'nope' >/dev/null || rc=$?
[ "$rc" -eq 1 ] || fail range-bad
ok range

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CONF=$TMP/config.json
LINKF=$TMP/link.txt
PUBF=$TMP/pub.txt
XRAY_BIN=$TMP/xray
cat > "$XRAY_BIN" <<'EOF'
#!/usr/bin/env bash
cfg=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-config" ]; then cfg=$arg; fi
  prev=$arg
done
if [ -n "$cfg" ] && grep -q 'bad.example:443' "$cfg"; then
  echo 'bad dest' >&2
  exit 1
fi
exit 0
EOF
chmod 755 "$XRAY_BIN"

printf '%s\n' '{"old":true}' > "$CONF"
prepare_xray_backup || fail backup
write_xray_config "$CONF" 443 bad.example uuid priv sid 1 0 || fail write-bad
commit_xray_config && fail should-rollback
grep -q '"old":true' "$CONF" || fail rolled-back
ok rollback

write_xray_config "$CONF" 443 addons.mozilla.org uuid-1 priv-1 sid-1 1 0 || fail write-good
python3 - "$CONF" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
assert cfg["inbounds"][0]["port"] == 443
assert cfg["inbounds"][0]["settings"]["clients"][0]["flow"] == "xtls-rprx-vision"
rs = cfg["inbounds"][0]["streamSettings"]["realitySettings"]
assert rs["dest"] == "addons.mozilla.org:443"
assert rs["serverNames"] == ["addons.mozilla.org"]
assert rs["minClientVer"] == "1.0.0"
assert "limitFallback" not in rs
sniff = cfg["inbounds"][0]["sniffing"]
assert sniff["enabled"] is True
assert sniff["destOverride"] == ["http", "tls", "quic"]
assert "routeOnly" not in sniff
assert cfg["outbounds"][0] == {"protocol": "freedom", "tag": "direct"}
assert cfg["outbounds"][1]["tag"] == "block"
assert cfg["outbounds"][1]["protocol"] == "blackhole"
rules = cfg["routing"]["rules"]
assert rules[0]["protocol"] == ["bittorrent"]
assert rules[0]["outboundTag"] == "block"
assert rules[1]["ip"] == ["geoip:private"]
assert cfg["routing"]["domainStrategy"] == "IPIfNonMatch"
assert all("geosite:cn" not in (r.get("domain") or []) for r in rules)
text = open(sys.argv[1], encoding="utf-8").read()
assert "mlkem" not in text
assert "X25519MLKEM768" not in text
PY
commit_xray_config || fail commit-good
config_blocks_cn "$CONF" && fail cn-off
write_xray_config "$CONF" 443 addons.mozilla.org uuid-1 priv-1 sid-1 0 1
python3 - "$CONF" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
rules = cfg["routing"]["rules"]
assert {"type": "field", "domain": ["geosite:cn"], "outboundTag": "block"} in rules
assert {"type": "field", "ip": ["geoip:cn"], "outboundTag": "block"} in rules
assert "minClientVer" not in cfg["inbounds"][0]["streamSettings"]["realitySettings"]
PY
config_blocks_cn "$CONF" || fail cn-on
ok xray-config

UUID=uuid-1 PORT=443 SNI=addons.mozilla.org PUB=pub-1 SID=sid-1
write_reality_link 203.0.113.8
grep -q 'fp=chrome' "$LINKF" || fail fp
grep -q 'support-x25519mlkem768' "$LINKF" && fail mlkem-link
grep -q 'flow=xtls-rprx-vision' "$LINKF" || fail flow
ok link

prepare_xray_backup
apply_dest_domain www.example.com || fail apply-dest
python3 - "$CONF" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
rs = cfg["inbounds"][0]["streamSettings"]["realitySettings"]
assert rs["dest"] == "www.example.com:443"
assert rs["serverNames"] == ["www.example.com"]
assert rs["privateKey"] == "priv-1"
assert cfg["inbounds"][0]["settings"]["clients"][0]["id"] == "uuid-1"
PY
grep -q 'sni=www.example.com' "$LINKF" || fail link-sni
grep -q 'fp=chrome' "$LINKF" || fail link-fp2
ok dest

# bad dest rolls the file back, including keys
printf '%s\n' "$PUB" > "$PUBF"
cp "$CONF" "$TMP/before-bad-dest.json"
# Force the fake xray to reject by patching through the normal writer after backup.
prepare_xray_backup
python3 - "$CONF" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["inbounds"][0]["streamSettings"]["realitySettings"]["dest"] = "bad.example:443"
json.dump(cfg, open(p, "w"))
PY
commit_xray_config && fail bad-dest-committed
python3 - "$CONF" "$TMP/before-bad-dest.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
assert a["inbounds"][0]["streamSettings"]["realitySettings"]["dest"] == b["inbounds"][0]["streamSettings"]["realitySettings"]["dest"]
PY
ok dest-rollback

jail=$(render_fail2ban_jail 2222 systemd "" ssh.service nftables '127.0.0.1/8 ::1 203.0.113.10')
printf '%s\n' "$jail" | grep -q 'port = 2222' || fail jail-port
printf '%s\n' "$jail" | grep -q 'backend = systemd' || fail jail-backend
printf '%s\n' "$jail" | grep -F -q 'journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session' || fail jail-match
printf '%s\n' "$jail" | grep -q 'banaction = nftables' || fail jail-nft
printf '%s\n' "$jail" | grep -q '203.0.113.10' || fail jail-ip
filejail=$(render_fail2ban_jail 22 auto /var/log/secure sshd.service iptables-multiport '127.0.0.1/8 ::1')
printf '%s\n' "$filejail" | grep -q 'logpath = /var/log/secure' || fail jail-log
printf '%s\n' "$filejail" | grep -q 'backend = auto' || fail jail-auto
ok jail-render

mock=$TMP/bin
mkdir -p "$mock" "$TMP/actions" "$TMP/logs"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$mock/nft"
chmod 755 "$mock/nft"
action=$(PATH="$mock" F2B_ACTION_DIR="$TMP/actions" detect_banaction || true)
[ -z "$action" ] || fail ban-missing-action
printf 'x\n' > "$TMP/actions/nftables.conf"
action=$(PATH="$mock" F2B_ACTION_DIR="$TMP/actions" detect_banaction)
[ "$action" = nftables ] || fail ban-nft-only
printf '%s\n' '#!/bin/sh' 'exit 0' > "$mock/iptables"
chmod 755 "$mock/iptables"
printf 'x\n' > "$TMP/actions/iptables-multiport.conf"
action=$(PATH="$mock" F2B_ACTION_DIR="$TMP/actions" detect_banaction)
[ "$action" = iptables-multiport ] || fail ban-iptables-preferred
cat > "$mock/systemctl" <<'EOF'
#!/bin/sh
if [ "$1" = is-active ] && [ "$2" = firewalld ]; then
  echo active
  exit 0
fi
exit 1
EOF
chmod 755 "$mock/systemctl"
printf 'x\n' > "$TMP/actions/firewallcmd-rich-rules.conf"
action=$(PATH="$mock" F2B_ACTION_DIR="$TMP/actions" detect_banaction)
[ "$action" = firewallcmd-rich-rules ] || fail ban-firewalld
ok banaction

cat > "$mock/sshd" <<'EOF'
#!/bin/sh
if [ "$1" = -T ]; then
  echo port 2222
  echo port 22
fi
EOF
chmod 755 "$mock/sshd"
ports=$(PATH="$mock:/usr/bin" detect_ssh_ports)
[ "$ports" = '2222,22' ] || fail ssh-ports
rm -f "$mock/systemctl"
cat > "$mock/systemctl" <<'EOF'
#!/bin/sh
if [ "$1" = cat ] && [ "$2" = ssh.service ]; then
  exit 0
fi
if [ "$1" = show ]; then
  echo "$5"
  exit 0
fi
exit 1
EOF
chmod 755 "$mock/systemctl"
unit=$(PATH="$mock" detect_ssh_unit || true)
[ "$unit" = ssh.service ] || fail unit-ssh
cat > "$mock/systemctl" <<'EOF'
#!/bin/sh
if [ "$1" = cat ] && [ "$2" = ssh.service ]; then
  exit 1
fi
if [ "$1" = cat ] && [ "$2" = sshd.service ]; then
  exit 0
fi
if [ "$1" = show ]; then
  echo "$5"
  exit 0
fi
exit 1
EOF
unit=$(PATH="$mock" detect_ssh_unit || true)
[ "$unit" = sshd.service ] || fail unit-sshd
REALITY_JOURNAL_OK=1
REALITY_LOG_DIR=$TMP/logs
backend=$(choose_ssh_log_backend ssh.service)
[ "$backend" = systemd ] || fail backend-journal
printf 'sshd\n' > "$TMP/logs/secure"
backend=$(choose_ssh_log_backend sshd.service)
[ "$backend" = "file:$TMP/logs/secure" ] || fail backend-file
REALITY_JOURNAL_OK=0
rm -f "$TMP/logs/secure"
choose_ssh_log_backend ssh.service && fail backend-none
unset REALITY_JOURNAL_OK REALITY_LOG_DIR
ok detect

home=$TMP/home
mkdir -p "$home/.ssh"
printf '%s\n' 'tester:x:1000:1000:test:'"$home"':/bin/bash' > "$TMP/passwd"
REALITY_PASSWD_FILE=$TMP/passwd
has_authorized_key && fail no-key
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTest user' > "$home/.ssh/authorized_keys"
has_authorized_key || fail has-key
[ "$FOUND_SSH_KEY_FILE" = "$home/.ssh/authorized_keys" ] || fail key-path
ok ssh-key

# subscription content: chrome fingerprint, no mlkem, hysteria link, CN direct rule kept
SUBDIR=$TMP/sub
SUBENV=$SUBDIR/sub.env
SUBPY=$SUBDIR/sub-server.py
SUBSVC=$TMP/reality-sub.service
HYENV=$TMP/hysteria.env
mkdir -p "$SUBDIR"
printf '%s\n' 'IP=203.0.113.8' 'SUBPORT=9' 'SUBPATH=abc' 'BIND=127.0.0.1' 'TUNNEL=0' 'TUNNEL_URL=' > "$SUBENV"
printf '%s\n' 'IP=203.0.113.8' 'PORT=23456' 'PASSWORD=secretPASS' 'SNI=addons.mozilla.org' 'PIN=AA:BB' 'HOP=20000-50000' 'NAME=Hy2-203.0.113.8' > "$HYENV"
printf '%s\n' 'pub-1' > "$PUBF"
write_xray_config "$CONF" 443 addons.mozilla.org uuid-1 priv-1 sid-1 1 0
write_sub_server
python3 -m py_compile "$SUBPY"
links=$(REALITY_SUBENV="$SUBENV" REALITY_XRAY_CONF="$CONF" REALITY_PUBF="$PUBF" REALITY_LINKF="$LINKF" REALITY_HYENV="$HYENV" REALITY_PRINT_LINKS=1 python3 "$SUBPY")
printf '%s\n' "$links" | grep -q 'fp=chrome' || fail sub-fp
printf '%s\n' "$links" | grep -q 'support-x25519mlkem768' && fail sub-mlkem
printf '%s\n' "$links" | grep -q 'hysteria2://secretPASS@203.0.113.8:20000-50000' || fail sub-hy2
printf '%s\n' "$links" | grep -q 'sni=addons.mozilla.org' || fail sub-sni
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
awk -v p="$port" 'BEGIN{FS=OFS="="} $1=="SUBPORT"{$2=p} {print}' "$SUBENV" > "$SUBENV.tmp"
mv "$SUBENV.tmp" "$SUBENV"
REALITY_SUBENV="$SUBENV" REALITY_XRAY_CONF="$CONF" REALITY_PUBF="$PUBF" REALITY_LINKF="$LINKF" REALITY_HYENV="$HYENV" \
  python3 "$SUBPY" >"$TMP/sub.out" 2>"$TMP/sub.err" &
spid=$!
sleep 0.3
body=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if body=$(curl -fsS "http://127.0.0.1:${port}/abc?target=v2ray"); then
    break
  fi
  sleep 0.2
done
clash=$(curl -fsS "http://127.0.0.1:${port}/abc?target=clash" || true)
kill "$spid" 2>/dev/null || true
wait "$spid" 2>/dev/null || true
[ -n "$body" ] || { cat "$TMP/sub.err" >&2; fail sub-http; }
decoded=$(printf '%s' "$body" | base64 -d)
printf '%s\n' "$decoded" | grep -q 'fp=chrome' || fail http-fp
printf '%s\n' "$decoded" | grep -q mlkem && fail http-mlkem
printf '%s\n' "$clash" | grep -q 'client-fingerprint: chrome' || fail clash-fp
printf '%s\n' "$clash" | grep -q 'type: hysteria2' || fail clash-hy2
printf '%s\n' "$clash" | grep -q 'ports: 20000-50000' || fail clash-hop
printf '%s\n' "$clash" | grep -q 'GEOIP,CN,DIRECT' || fail clash-cn-direct
ok subscription

printf '%s\n' 'IP,ORIGIN,TLS,ALPN,CURVE,CERT_LENGTH,CERT_SIGNATURE,CERT_PUBLICKEY,CERT_DOMAIN,CERT_ISSUER,GEO_CODE' \
  '1.1.1.1,1.1.1.1,TLS 1.3,h2,x,1,a,b,good.example.com,"Let'\''s Encrypt",US' \
  '1.1.1.2,1.1.1.2,TLS 1.3,h2,x,1,a,b,*.wild.example,"Let'\''s Encrypt",US' \
  '1.1.1.3,1.1.1.3,TLS 1.2,http/1.1,x,1,a,b,old.example,"Let'\''s Encrypt",US' \
  '1.1.1.4,1.1.1.4,TLS 1.3,h2,x,1,a,b,redir.example,"Let'\''s Encrypt",US' \
  > "$TMP/scan.csv"
printf '%s\n' 'good.example.com 200' 'redir.example 301' > "$TMP/redir.map"
mapfile -t found < <(REALITY_REDIRECT_MAP="$TMP/redir.map" list_scan_candidates "$TMP/scan.csv")
[ "${#found[@]}" -eq 1 ] || fail scan-count
[ "${found[0]}" = good.example.com ] || fail scan-domain
ok scanner

HOP_SH=$TMP/hy2-hop.sh
HOP_ENV=$TMP/hy2-hop.env
write_hop_helper
shellcheck -S info "$HOP_SH"
bash -n "$HOP_SH"
ok hop-script

if [ "${RUN_XRAY_BIN:-1}" = 1 ]; then
  zip=$TMP/xray.zip
  if curl -fL --retry 3 --max-time 120 -o "$zip" "https://github.com/XTLS/Xray-core/releases/download/v26.7.28/Xray-linux-64.zip"; then
    unzip -q -o "$zip" -d "$TMP/xray-real"
    XRAY_BIN=$TMP/xray-real/xray
    chmod 755 "$XRAY_BIN"
    XRAY_LOCATION_ASSET=$TMP/xray-real
    real_uuid=$("$XRAY_BIN" uuid)
    real_keys=$("$XRAY_BIN" x25519)
    real_priv=$(printf '%s\n' "$real_keys" | awk -F': ' '/Private/{print $2; exit}')
    real_pub=$(printf '%s\n' "$real_keys" | awk -F': ' '/Public|Password/{print $2; exit}')
    if [ -z "$real_priv" ] || [ -z "$real_pub" ]; then
      printf '%s\n' "$real_keys" >&2
      fail x25519-parse
    fi
    real_sid=$(openssl rand -hex 8)
    write_xray_config "$CONF" 443 addons.mozilla.org "$real_uuid" "$real_priv" "$real_sid" 1 0
    xray_test || fail real-xray-test
    write_xray_config "$CONF" 443 addons.mozilla.org "$real_uuid" "$real_priv" "$real_sid" 1 1
    xray_test || fail real-xray-cn
    python3 - "$CONF" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["inbounds"][0]["streamSettings"]["realitySettings"]["dest"] = ""
json.dump(cfg, open(p, "w"))
PY
    if xray_test; then
      fail real-xray-should-fail
    fi
    ok real-xray
  else
    echo "skip real-xray (download failed)"
  fi
fi

echo "smoke passed"
