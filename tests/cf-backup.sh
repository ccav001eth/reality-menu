#!/usr/bin/env bash
# 虚构数据：203.0.113.10、alpha-fake / beta-fake.trycloudflare.com、
# UUID 11111111-1111-4111-8111-111111111111、密钥 fictional-private-key。
# 不连接真实 Cloudflare，也不使用真实订阅口令。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ORIG_PATH=$PATH
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok %s\n' "$*"; }

bash -n "$ROOT/reality-menu.sh"
bash -n "$ROOT/tests/cf-backup.sh"

load() {
  unset XRAY_VERSION SUB_TUNNEL SUBSCRIPTION CF_PORT CF_WSPATH SUB_TUNNEL_WAIT CF_TUNNEL_WAIT || true
  AUTO=0
  # shellcheck disable=SC1091
  source "$ROOT/reality-menu.sh"
  CONF=$TMP/config.json
  LINKF=$TMP/link.txt
  PUBF=$TMP/pub.txt
  SUBDIR=$TMP/sub
  SUBENV=$SUBDIR/sub.env
  SUBPY=$SUBDIR/sub-server.py
  SUBSVC=$TMP/reality-sub.service
  SUBTUNSVC=$TMP/reality-tunnel.service
  SUBURLF=$TMP/reality-sub.url
  CFDIR=$TMP/cf
  CFENV=$CFDIR/cf.env
  CFSVC=$TMP/reality-cf.service
  HYENV=$TMP/hy.env
  XRAY_BIN=$TMP/xray
  mkdir -p "$SUBDIR" "$CFDIR"
  rm -f "$SUBURLF" "$CFENV" "$CONF"
  case "$CONF" in
    "$TMP"/*) ;;
    *) fail conf-escaped ;;
  esac
}

write_fake_xray() {
  cat > "$XRAY_BIN" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod 755 "$XRAY_BIN"
}

write_reality() {
  write_xray_config "$CONF" 443 dest.example.com 11111111-1111-4111-8111-111111111111 fictional-private-key fictional-sid 0 0
  printf 'fictional-public-key\n' > "$PUBF"
  printf '%s\n' \
    'IP=203.0.113.10' \
    'SUBPORT=38921' \
    'SUBPATH=fakepath0123456789abcdef0123456789ab' \
    'BIND=0.0.0.0' \
    'TUNNEL=0' \
    'TUNNEL_URL=' \
    > "$SUBENV"
  chmod 600 "$SUBENV"
}

install_mocks() {
  BIN=$TMP/bin
  rm -rf "$BIN"
  mkdir -p "$BIN"
  export SYSLOG=$TMP/syslog
  : > "$SYSLOG"
  cat > "$BIN/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SYSLOG"
if [ "$1" = is-active ]; then
  unit=$2
  if [ "$unit" = --quiet ]; then unit=$3; fi
  if grep -F -qx "restart ${unit}" "$SYSLOG" || grep -F -qx "reload ${unit}" "$SYSLOG"; then
    exit 0
  fi
  exit 1
fi
if [ "$1" = show ]; then
  unit=$2
  file=""
  if [ "$unit" = reality-cf ]; then file=${CFSVC:-}; fi
  if [ "$unit" = reality-tunnel ]; then file=${SUBTUNSVC:-}; fi
  if [ -n "$file" ] && [ -f "$file" ]; then
    sed -n 's/^ExecStart=//p' "$file"
  fi
  exit 0
fi
if [ "$1" = reload ] && [ "$2" = xray ]; then
  [ "${MOCK_RELOAD_FAIL:-0}" != 1 ]
  exit $?
fi
if [ "$1" = restart ] && [ "$2" = xray ]; then
  [ "${MOCK_RESTART_XRAY_FAIL:-0}" != 1 ]
  exit $?
fi
exit 0
EOF
  cat > "$BIN/journalctl" <<'EOF'
#!/bin/bash
unit=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-u" ]; then unit=$arg; fi
  prev=$arg
done
case "$unit" in
  reality-tunnel) printf '%s\n' "${MOCK_SUB_JOURNAL:-}" ;;
  reality-cf) printf '%s\n' "${MOCK_CF_JOURNAL:-}" ;;
esac
exit 0
EOF
  chmod 755 "$BIN/systemctl" "$BIN/journalctl"
  export PATH="$BIN:$ORIG_PATH"
  export SUBTUNSVC CFSVC SYSLOG
  systemd_booted() { return 0; }
  ensure_cloudflared() { return 0; }
  export MOCK_SUB_JOURNAL='https://alpha-fake.trycloudflare.com'
  export MOCK_CF_JOURNAL='https://beta-fake.trycloudflare.com'
  export CF_PORT=18080
  export CF_WSPATH=/wsfictionaltoken
}

count_exact() {
  local want=$1
  if [ ! -s "$SYSLOG" ]; then
    printf '0\n'
    return 0
  fi
  grep -F -cx "$want" "$SYSLOG" || true
}

load
write_fake_xray
write_reality
before=$(reality_fingerprint)
declare -f deploy | grep -q enable_cf_backup && fail deploy-calls-cf
declare -f main | grep -q 'enable_cf_backup' || fail main-cf
python3 - "$CONF" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
assert all(ib.get("tag") != "reality-menu-cf" for ib in cfg["inbounds"])
assert cfg["inbounds"][0]["streamSettings"]["security"] == "reality"
assert cfg["inbounds"][0]["port"] == 443
PY
ok default-has-no-cf-inbound

load
write_fake_xray
write_reality
install_mocks
: > "$SYSLOG"
enable_cf_backup >"$TMP/out-cf.txt" 2>"$TMP/err-cf.txt" || { cat "$TMP/err-cf.txt" >&2; fail cf-enable; }
sub_url='https://alpha-fake.trycloudflare.com/fakepath0123456789abcdef0123456789ab'
printf '%s\n%s\n' "$SUBURLF" "$sub_url" > "$TMP/expect-cf.txt"
cmp "$TMP/expect-cf.txt" "$TMP/out-cf.txt" || { printf 'stdout:\n' >&2; cat "$TMP/out-cf.txt" >&2; fail cf-stdout; }
grep -q 'vless://' "$TMP/out-cf.txt" && fail cf-stdout-vless
grep -q 'beta-fake' "$TMP/out-cf.txt" && fail cf-stdout-is-data-host
grep -q 'HTTPS 订阅入口' "$TMP/err-cf.txt" || fail cf-stderr-entry
grep -q '数据' "$TMP/err-cf.txt" || fail cf-stderr-data
grep -q '不保证' "$TMP/err-cf.txt" || fail cf-stderr-limit
[ "$(reality_fingerprint)" = "$before" ] || fail cf-changed-reality
python3 - "$CONF" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
found = [ib for ib in cfg["inbounds"] if ib.get("tag") == "reality-menu-cf"]
assert len(found) == 1
ib = found[0]
assert ib["listen"] == "127.0.0.1"
assert ib["port"] == 18080
assert ib["port"] != 443
assert ib["streamSettings"]["network"] == "ws"
assert ib["streamSettings"]["security"] == "none"
assert ib["streamSettings"]["wsSettings"]["path"] == "/wsfictionaltoken"
assert ib["settings"]["clients"][0]["id"] == "11111111-1111-4111-8111-111111111111"
assert "flow" not in ib["settings"]["clients"][0]
assert cfg["inbounds"][0]["streamSettings"]["realitySettings"]["privateKey"] == "fictional-private-key"
PY
grep -q 'http://127.0.0.1:38921' "$SUBTUNSVC" || fail sub-tunnel-port
grep -q 'http://127.0.0.1:18080' "$CFSVC" || fail data-tunnel-port
[ "$(count_exact 'restart reality-tunnel')" -eq 1 ] || fail tunnel-restart-count
[ "$(count_exact 'restart reality-cf')" -eq 1 ] || fail data-restart-count
[ "$(count_exact 'reload xray')" -eq 1 ] || fail xray-reload-count
[ "$(count_exact 'restart xray')" -eq 0 ] || fail xray-restarted
enable_cf_backup >"$TMP/out-cf2.txt" 2>"$TMP/err-cf2.txt" || fail cf-second
cmp "$TMP/expect-cf.txt" "$TMP/out-cf2.txt" || fail cf-second-stdout
[ "$(count_exact 'restart reality-tunnel')" -eq 1 ] || fail second-restarted-sub-tunnel
[ "$(count_exact 'restart reality-cf')" -eq 1 ] || fail second-restarted-data-tunnel
[ "$(count_exact 'reload xray')" -eq 1 ] || fail second-reloaded-xray
[ "$(count_exact 'restart xray')" -eq 0 ] || fail second-restarted-xray
python3 - "$CONF" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
assert sum(1 for ib in cfg["inbounds"] if ib.get("tag") == "reality-menu-cf") == 1
PY
start_cf_data_tunnel 18080 >/dev/null 2>&1 || fail data-again
[ "$(count_exact 'restart reality-tunnel')" -eq 1 ] || fail data-restart-woke-sub
[ "$(count_exact 'restart reality-cf')" -eq 1 ] || fail data-again-restarted
start_cloudflare_tunnel >/dev/null 2>&1 || fail sub-again
[ "$(count_exact 'restart reality-cf')" -eq 1 ] || fail sub-restart-woke-data
[ "$(count_exact 'restart reality-tunnel')" -eq 1 ] || fail sub-again-restarted
ok cf-idempotent-independent

load
write_fake_xray
write_reality
install_mocks
export CF_TUNNEL_WAIT=1
export MOCK_CF_JOURNAL=''
: > "$SYSLOG"
rc=0
enable_cf_backup >"$TMP/out-datafail.txt" 2>"$TMP/err-datafail.txt" || rc=$?
[ "$rc" -ne 0 ] || fail data-fail-succeeded
grep -q '数据隧道失败' "$TMP/err-datafail.txt" || fail data-fail-message
grep -q '不视为成功' "$TMP/err-datafail.txt" || fail data-fail-not-success
[ ! -s "$TMP/out-datafail.txt" ] || fail data-fail-stdout
[ "$(reality_fingerprint)" = "$before" ] || fail data-fail-reality
python3 - "$CONF" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
assert all(ib.get("tag") != "reality-menu-cf" for ib in cfg["inbounds"])
PY
[ ! -f "$CFENV" ] || fail data-fail-left-env
grep -q 'http://' "$TMP/out-datafail.txt" && fail data-fail-http
ok cf-data-rollback

load
write_fake_xray
write_reality
install_mocks
export SUB_TUNNEL_WAIT=1
export CF_TUNNEL_WAIT=1
export MOCK_SUB_JOURNAL=''
export MOCK_CF_JOURNAL=''
: > "$SYSLOG"
rc=0
enable_cf_backup >"$TMP/out-subfail.txt" 2>"$TMP/err-subfail.txt" || rc=$?
[ "$rc" -ne 0 ] || fail sub-fail-succeeded
grep -q 'HTTPS 订阅入口失败' "$TMP/err-subfail.txt" || fail sub-fail-message
grep -q '不视为成功' "$TMP/err-subfail.txt" || fail sub-fail-not-success
grep -q '明文 HTTP' "$TMP/err-subfail.txt" || fail sub-fail-http-note
[ "$(count_exact 'restart reality-cf')" -eq 0 ] || fail sub-fail-started-data
python3 - "$CONF" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
assert all(ib.get("tag") != "reality-menu-cf" for ib in cfg["inbounds"])
PY
[ "$(reality_fingerprint)" = "$before" ] || fail sub-fail-reality
ok cf-sub-fail-no-data

load
write_fake_xray
write_reality
install_mocks
write_cf_env() {
  printf 'PORT=%s\nWSPATH=/not-the-real-path\nHOST=beta-fake.trycloudflare.com\nURL=https://beta-fake.trycloudflare.com\n' "$1" > "$CFENV"
}
: > "$SYSLOG"
rc=0
enable_cf_backup >"$TMP/out-mismatch.txt" 2>"$TMP/err-mismatch.txt" || rc=$?
[ "$rc" -ne 0 ] || fail mismatch-succeeded
grep -q '不一致' "$TMP/err-mismatch.txt" || fail mismatch-message
grep -q '不视为成功' "$TMP/err-mismatch.txt" || fail mismatch-not-success
python3 - "$CONF" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
assert all(ib.get("tag") != "reality-menu-cf" for ib in cfg["inbounds"])
PY
[ "$(reality_fingerprint)" = "$before" ] || fail mismatch-reality
ok cf-mismatch-rollback

load
write_reality
CF_PORT=18080
CF_WSPATH=/wsfictionaltoken
upsert_cf_inbound 18080 /wsfictionaltoken >/dev/null || fail upsert
printf '%s\n' \
  'PORT=18080' \
  'WSPATH=/wsfictionaltoken' \
  'HOST=beta-fake.trycloudflare.com' \
  'URL=https://beta-fake.trycloudflare.com' \
  > "$CFENV"
write_sub_server
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
awk -v p="$port" 'BEGIN{FS=OFS="="} $1=="SUBPORT"{$2=p} $1=="BIND"{$2="127.0.0.1"} {print}' "$SUBENV" > "$SUBENV.tmp"
mv "$SUBENV.tmp" "$SUBENV"
REALITY_SUBENV="$SUBENV" REALITY_XRAY_CONF="$CONF" REALITY_PUBF="$PUBF" REALITY_LINKF="$LINKF" REALITY_HYENV="$HYENV" REALITY_CFENV="$CFENV" \
  python3 "$SUBPY" >"$TMP/srv.out" 2>"$TMP/srv.err" &
spid=$!
code=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  code=$(curl -s -o "$TMP/body.txt" -w '%{http_code}' -A 'okhttp/4.12.0' "http://127.0.0.1:${port}/fakepath0123456789abcdef0123456789ab" 2>/dev/null || true)
  [ "$code" = 200 ] && break
  sleep 0.2
done
wrong=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/wrong-token-fictional" || true)
clash=$(curl -fsS -A 'okhttp/4.12.0' "http://127.0.0.1:${port}/fakepath0123456789abcdef0123456789ab?target=clash")
kill "$spid" 2>/dev/null || true
wait "$spid" 2>/dev/null || true
[ "$code" = 200 ] || { cat "$TMP/srv.err" >&2; fail token-ok; }
[ "$wrong" = 404 ] || fail token-wrong
python3 - "$TMP/body.txt" "$CONF" "$CFENV" <<'PY'
import base64, json, sys, urllib.parse
body, conf, envp = sys.argv[1:]
text = base64.b64decode(open(body, "rb").read()).decode()
cfg = json.load(open(conf, encoding="utf-8"))
env = {}
for line in open(envp, encoding="utf-8"):
    line = line.strip()
    if not line or "=" not in line:
        continue
    k, v = line.split("=", 1)
    env[k] = v
ws = [ib for ib in cfg["inbounds"] if ib.get("tag") == "reality-menu-cf"][0]
link = next(line for line in text.splitlines() if "type=ws" in line)
parsed = urllib.parse.urlparse(link)
q = urllib.parse.parse_qs(parsed.query)
assert parsed.scheme == "vless"
assert parsed.hostname == env["HOST"] == "beta-fake.trycloudflare.com"
assert parsed.port == 443
assert q["security"] == ["tls"]
assert q["type"] == ["ws"]
assert q["sni"] == [env["HOST"]]
assert q["host"] == [env["HOST"]]
assert q["path"] == [env["WSPATH"]] == [ws["streamSettings"]["wsSettings"]["path"]]
assert urllib.parse.unquote(parsed.username) == ws["settings"]["clients"][0]["id"]
assert "pbk" not in q
assert "flow" not in q
assert ws["listen"] == "127.0.0.1"
assert ws["streamSettings"]["security"] == "none"
assert ws["port"] == 18080
assert "11111111-1111-4111-8111-111111111111" in link
PY
printf '%s\n' "$clash" > "$TMP/clash.txt"
python3 - "$TMP/clash.txt" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
assert "network: ws" in text
assert "tls: true" in text
assert "path: /wsfictionaltoken" in text or 'path: "/wsfictionaltoken"' in text
assert "beta-fake.trycloudflare.com" in text
assert "11111111-1111-4111-8111-111111111111" in text
start = text.index("CF-ws-")
block = text[start:text.index("proxy-groups:")]
assert "reality-opts:" not in block
assert "\n    flow:" not in block
PY
printf '%s\n' 'PORT=18080' 'WSPATH=/other-path' 'HOST=beta-fake.trycloudflare.com' 'URL=https://beta-fake.trycloudflare.com' > "$CFENV"
links=$(REALITY_SUBENV="$SUBENV" REALITY_XRAY_CONF="$CONF" REALITY_PUBF="$PUBF" REALITY_LINKF="$LINKF" REALITY_HYENV="$HYENV" REALITY_CFENV="$CFENV" REALITY_PRINT_LINKS=1 python3 "$SUBPY")
printf '%s\n' "$links" | grep -q 'type=ws' && fail mismatch-still-advertised
ok cf-tls-token-consistency

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$ROOT/reality-menu.sh"
  shellcheck -S warning -e SC2034 "$ROOT/tests/cf-backup.sh"
  ok shellcheck
fi

echo "cf-backup passed"
