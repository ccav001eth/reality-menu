#!/usr/bin/env bash
# 虚构数据：203.0.113.10、dest.example.com、alpha-fake/beta-fake.trycloudflare.com、
# UUID 11111111-1111-4111-8111-111111111111、密钥 fictional-private-key / fictional-public-key。
# 这些值只用于本机 mock，不是真实节点、订阅口令或隧道。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ORIG_PATH=$PATH
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok %s\n' "$*"; }

bash -n "$ROOT/reality-menu.sh"
bash -n "$ROOT/tests/apt-and-sub.sh"
if grep -E 'apt(-get)?[[:space:]]+(full-upgrade|dist-upgrade|upgrade)\b' "$ROOT/reality-menu.sh"; then
  fail upgrade-command
fi
if grep -E 'sources\.list|/var/lib/apt/lists/lock|/var/lib/dpkg/lock' "$ROOT/reality-menu.sh"; then
  fail apt-source-or-lock
fi
if grep -F 'update -qq || true' "$ROOT/reality-menu.sh"; then
  fail swallowed-update
fi
grep -q '1) deploy || true' "$ROOT/reality-menu.sh" || fail menu-calls-deploy
grep -q '8) enable_subscription_from_menu || true' "$ROOT/reality-menu.sh" || fail menu-calls-sub
grep -q 'finish_install $?' "$ROOT/reality-menu.sh" || fail install-uses-finish
ok static

fresh() {
  unset XRAY_VERSION SUB_TUNNEL SUBSCRIPTION FAIL2BAN HYSTERIA2 DISABLE_SSH_PASSWORD PKG_UPDATED || true
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
  SUBURLF=$TMP/reality-sub.url
  HYENV=$TMP/hy.env
  HYCONF=$TMP/hy.yaml
  HYLINK=$TMP/hy.link
  F2B_JAIL=$TMP/jail.local
  HOP_ENV=$TMP/hop.env
  HOP_SH=$TMP/hop.sh
  XRAY_BIN=$TMP/xray
  mkdir -p "$SUBDIR"
  case "$CONF" in
    "$TMP"/*) ;;
    *) fail conf-escaped ;;
  esac
  case "$SUBURLF" in
    "$TMP"/*) ;;
    *) fail url-escaped ;;
  esac
  rm -f "$SUBURLF"
}

write_fake_xray() {
  cat > "$XRAY_BIN" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${XLOG:-/dev/null}"
case "${1:-}" in
  uuid) printf '%s\n' '11111111-1111-4111-8111-111111111111' ;;
  x25519)
    printf '%s\n' 'Private key: fictional-private-key'
    printf '%s\n' 'Public key: fictional-public-key'
    ;;
  version) printf '%s\n' 'Xray 26.7.28' ;;
esac
exit 0
EOF
  chmod 755 "$XRAY_BIN"
}

apt_sandbox() {
  local mode=$1
  BIN=$TMP/bin-$mode
  rm -rf "$BIN"
  mkdir -p "$BIN"
  LOG=$TMP/apt-$mode.log
  : > "$LOG"
  UPDATED=$TMP/updated-$mode
  rm -f "$UPDATED"
  CA=$TMP/ca-$mode.crt
  rm -f "$CA"
  export REALITY_CA_BUNDLE=$CA
  export MOCK_LOG=$LOG MOCK_UPDATED=$UPDATED MOCK_BIN=$BIN MOCK_CA=$CA
  export MOCK_INDEX=${2:-empty}
  export FAIL_UPDATE=${3:-0}
  export FAIL_INSTALL=${4:-0}
  export MOCK_SKIP_CREATE=${5:-0}
  cat > "$BIN/apt-get" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_LOG"
if [ "$1" = update ]; then
  if [ "$FAIL_UPDATE" = 1 ]; then
    echo "E: mock apt update failed" >&2
    exit 1
  fi
  printf 'refreshed\n' > "$MOCK_UPDATED"
  exit 0
fi
if [ "$1" = install ]; then
  if [ ! -f "$MOCK_UPDATED" ]; then
    if [ "$MOCK_INDEX" = stale ]; then
      echo "E: Package unzip has no installation candidate (stale mirrors.aliyun.com lists)" >&2
    else
      echo "E: Unable to locate package unzip (empty package index)" >&2
    fi
    exit 100
  fi
  if [ "$FAIL_INSTALL" = 1 ]; then
    echo "E: mock apt install failed" >&2
    exit 100
  fi
  if [ "$MOCK_SKIP_CREATE" = 1 ]; then
    exit 0
  fi
  shift
  for arg in "$@"; do
    case "$arg" in
      -y) ;;
      curl|unzip|openssl|python3)
        printf '%s\n' '#!/bin/sh' 'exit 0' > "$MOCK_BIN/$arg"
        chmod 755 "$MOCK_BIN/$arg"
        ;;
      ca-certificates)
        mkdir -p "$(dirname "$MOCK_CA")"
        printf 'fake-ca\n' > "$MOCK_CA"
        ;;
      *)
        echo "unexpected package $arg" >&2
        exit 99
        ;;
    esac
  done
  exit 0
fi
echo "unexpected apt-get $*" >&2
exit 99
EOF
  chmod 755 "$BIN/apt-get"
  local cmd tool
  for cmd in curl openssl python3; do
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$BIN/$cmd"
    chmod 755 "$BIN/$cmd"
  done
  export PATH="$ORIG_PATH"
  for tool in mktemp cat rm chmod mkdir dirname; do
    ln -sf "$(command -v "$tool")" "$BIN/$tool"
  done
  unset PKG_UPDATED
}

run_ensure() {
  PATH="$BIN" ensure_install_deps
}

fresh
apt_sandbox empty empty 0 0 0
out=$TMP/out-empty.txt
run_ensure >"$out" 2>&1 || fail empty-index
grep -q '^update$' "$LOG" || fail empty-no-update
grep -q '^install -y unzip ca-certificates$' "$LOG" || fail empty-install-args
[ "$(grep -c '^update$' "$LOG")" -eq 1 ] || fail empty-update-count
[ -x "$BIN/unzip" ] || fail empty-unzip-missing
[ -s "$CA" ] || fail empty-ca-missing
grep -q 'no installation candidate' "$out" && fail empty-saw-stale-error
grep -q 'Unable to locate package' "$out" && fail empty-saw-empty-error
ok apt-empty-index

fresh
apt_sandbox stale stale 0 0 0
run_ensure >"$TMP/out-stale.txt" 2>&1 || fail stale-index
grep -q '^update$' "$LOG" || fail stale-no-update
[ "$(grep -n . "$LOG" | head -n 1)" = "1:update" ] || fail stale-update-not-first
grep -q 'mirrors.aliyun.com' "$TMP/out-stale.txt" && fail stale-installed-before-update
[ -x "$BIN/unzip" ] || fail stale-unzip-missing
ok apt-stale-index

fresh
apt_sandbox noupdate empty 1 0 0
rc=0
run_ensure >"$TMP/out-noupdate.txt" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail update-should-fail
grep -q '^update$' "$LOG" || fail update-fail-not-called
grep -q '^install ' "$LOG" && fail update-fail-still-installed
grep -q '已中止' "$TMP/out-noupdate.txt" || fail update-fail-message
grep -q '已停止' "$TMP/out-noupdate.txt" || fail update-fail-stop
[ -x "$BIN/unzip" ] && fail update-fail-created-unzip
ok apt-update-fails

fresh
apt_sandbox noinst empty 0 1 0
rc=0
run_ensure >"$TMP/out-noinst.txt" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail install-should-fail
grep -q '^update$' "$LOG" || fail install-fail-no-update
grep -q '^install -y unzip ca-certificates$' "$LOG" || fail install-fail-no-install
[ -x "$BIN/unzip" ] && fail install-fail-created
grep -q '已停止' "$TMP/out-noinst.txt" || fail install-fail-message
ok apt-install-fails

fresh
apt_sandbox skipcreate empty 0 0 1
rc=0
run_ensure >"$TMP/out-skip.txt" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail false-success
grep -q '不会当作安装成功' "$TMP/out-skip.txt" || fail false-success-message
ok apt-false-success

fresh
apt_sandbox present empty 0 0 0
printf '%s\n' '#!/bin/sh' 'exit 0' > "$BIN/unzip"
chmod 755 "$BIN/unzip"
printf 'fake-ca\n' > "$CA"
run_ensure >"$TMP/out-present.txt" 2>&1 || fail already-present
[ ! -s "$LOG" ] || fail already-present-called-apt
grep -q '正在更新软件包索引' "$TMP/out-present.txt" && fail already-present-updated
run_ensure || fail already-present-again
[ ! -s "$LOG" ] || fail already-present-second
ok apt-already-present

fresh
apt_sandbox idem empty 0 0 0
run_ensure >/dev/null || fail idem-first
run_ensure >/dev/null || fail idem-second
[ "$(grep -c '^update$' "$LOG")" -eq 1 ] || fail idem-update
[ "$(grep -c '^install ' "$LOG")" -eq 1 ] || fail idem-install
ok apt-idempotent

fresh
BIN=$TMP/bin-dnf
rm -rf "$BIN"
mkdir -p "$BIN"
LOG=$TMP/dnf.log
: > "$LOG"
CA=$TMP/ca-dnf.crt
printf 'fake-ca\n' > "$CA"
export REALITY_CA_BUNDLE=$CA
export MOCK_LOG=$LOG MOCK_BIN=$BIN
for cmd in curl openssl python3; do
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$BIN/$cmd"
  chmod 755 "$BIN/$cmd"
done
cat > "$BIN/dnf" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_LOG"
[ "$1" = install ] || { echo "unexpected dnf $*" >&2; exit 99; }
shift
for arg in "$@"; do
  case "$arg" in
    -y) ;;
    curl|unzip|openssl|python3|ca-certificates)
      if [ "$arg" != ca-certificates ]; then
        printf '%s\n' '#!/bin/sh' 'exit 0' > "$MOCK_BIN/$arg"
        chmod 755 "$MOCK_BIN/$arg"
      fi
      ;;
    *) echo "unexpected dnf package $arg" >&2; exit 99 ;;
  esac
done
exit 0
EOF
chmod 755 "$BIN/dnf"
export PATH="$ORIG_PATH"
for tool in mktemp cat rm chmod mkdir dirname; do
  ln -sf "$(command -v "$tool")" "$BIN/$tool"
done
unset PKG_UPDATED
if PATH="$BIN" command -v apt-get >/dev/null 2>&1; then
  fail dnf-still-sees-apt
fi
PATH="$BIN" ensure_install_deps >"$TMP/out-dnf.txt" 2>&1 || fail dnf-install
grep -q '^install -y unzip$' "$LOG" || fail dnf-args
grep -q update "$LOG" && fail dnf-updated
[ -x "$BIN/unzip" ] || fail dnf-unzip
ok dnf-unchanged

fresh
export PATH="$ORIG_PATH"
BIN=$TMP/bin-curl
mkdir -p "$BIN"
printf '%s\n' '#!/bin/sh' 'echo curled >> "$MOCK_CURL_LOG"' 'exit 0' > "$BIN/curl"
chmod 755 "$BIN/curl"
export MOCK_CURL_LOG=$TMP/curl.log
: > "$MOCK_CURL_LOG"
export PATH="$BIN:$ORIG_PATH"
ensure_install_deps() { return 1; }
rc=0
install_xray v26.7.28 >"$TMP/out-ix.txt" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail xray-should-stop
[ ! -s "$MOCK_CURL_LOG" ] || fail xray-downloaded
ok install-stops-before-download

export PATH="$ORIG_PATH"
unset REALITY_CA_BUNDLE || true

fresh
export PATH="$ORIG_PATH"
write_fake_xray
export XLOG=$TMP/xlog
: > "$XLOG"
printf 'fictional-public-key\n' > "$PUBF"
python3 - "$CONF" <<'PY'
import json, sys
json.dump({"marker": "before"}, open(sys.argv[1], "w"))
PY
before=$(md5sum "$CONF" | awk '{print $1}')
mkdir -p "$SUBDIR"
printf '%s\n' \
  'IP=203.0.113.10' \
  'SUBPORT=38921' \
  'SUBPATH=fakepath0123456789abcdef0123456789ab' \
  'BIND=127.0.0.1' \
  'TUNNEL=1' \
  'TUNNEL_URL=' \
  > "$SUBENV"
chmod 600 "$SUBENV"
printf 'https://alpha-fake.trycloudflare.com/old\n' > "$SUBURLF"
systemd_booted() { return 0; }
start_cloudflare_tunnel() { return 1; }
fw_open_tcp() { echo "open $1" >> "$TMP/fwlog"; }
fw_close_tcp() { echo "close $1" >> "$TMP/fwlog"; }
: > "$TMP/fwlog"
rc=0
sub_enable >"$TMP/out-tfail.txt" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail tunnel-fail-succeeded
[ -f "$SUBURLF" ] && fail tunnel-fail-wrote-url
grep -q 'http://' "$TMP/out-tfail.txt" && fail tunnel-fail-printed-http
grep -q '明文' "$TMP/out-tfail.txt" || fail tunnel-fail-message
grep -q '^open ' "$TMP/fwlog" && fail tunnel-fail-opened-fw
now=$(md5sum "$CONF" | awk '{print $1}')
[ "$now" = "$before" ] || fail tunnel-fail-changed-config
[ ! -s "$XLOG" ] || fail tunnel-fail-called-xray
ok tunnel-fail-closed

fresh
export PATH="$ORIG_PATH"
write_fake_xray
export XLOG=$TMP/xlog2
: > "$XLOG"
write_xray_config "$CONF" 443 dest.example.com 11111111-1111-4111-8111-111111111111 fictional-private-key fictional-sid 0 0
printf 'fictional-public-key\n' > "$PUBF"
before=$(md5sum "$CONF" | awk '{print $1}')
mkdir -p "$SUBDIR"
printf '%s\n' \
  'IP=203.0.113.10' \
  'SUBPORT=38921' \
  'SUBPATH=fakepath0123456789abcdef0123456789ab' \
  'BIND=0.0.0.0' \
  'TUNNEL=0' \
  'TUNNEL_URL=' \
  > "$SUBENV"
BIN=$TMP/bin-sub
rm -rf "$BIN"
mkdir -p "$BIN"
export SYSLOG=$TMP/syslog
: > "$SYSLOG"
export MOCK_TUNNEL_ACTIVE=1
export MOCK_JOURNAL='cloudflared https://alpha-fake.trycloudflare.com connected'
cat > "$BIN/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SYSLOG"
if [ "$1" = restart ] && [ "$2" = xray ]; then
  exit 1
fi
if [ "$1" = is-active ]; then
  unit=$2
  if [ "$unit" = --quiet ]; then
    unit=$3
  fi
  if [ "$unit" = reality-tunnel ]; then
    [ "${MOCK_TUNNEL_ACTIVE:-1}" = 1 ]
    exit $?
  fi
  exit 0
fi
exit 0
EOF
cat > "$BIN/journalctl" <<'EOF'
#!/bin/bash
printf '%s\n' "${MOCK_JOURNAL:-}"
exit 0
EOF
export QRLOG=$TMP/qrlog
: > "$QRLOG"
cat > "$BIN/qrencode" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$QRLOG"
exit 0
EOF
chmod 755 "$BIN/systemctl" "$BIN/journalctl" "$BIN/qrencode"
export PATH="$BIN:$ORIG_PATH"
systemd_booted() { return 0; }
start_cloudflare_tunnel() {
  upsert_env "$SUBENV" TUNNEL_URL "https://alpha-fake.trycloudflare.com"
  return 0
}
fw_open_tcp() { echo "open $1" >> "$TMP/fwlog2"; }
fw_close_tcp() { echo "close $1" >> "$TMP/fwlog2"; }
: > "$TMP/fwlog2"
SUB_TUNNEL=1
sub_enable >"$TMP/out-tok.txt" 2>"$TMP/err-tok.txt" || fail tunnel-ok
url='https://alpha-fake.trycloudflare.com/fakepath0123456789abcdef0123456789ab'
[ "$(cat "$SUBURLF")" = "$url" ] || fail tunnel-url-file
[ "$(wc -l < "$SUBURLF")" -eq 1 ] || fail tunnel-url-lines
grep -q 'vless://' "$SUBURLF" && fail tunnel-url-is-vless
[ "$(stat -c %a "$SUBURLF")" = 600 ] || fail tunnel-url-mode
printf '%s\n%s\n' "$SUBURLF" "$url" > "$TMP/expect-tok.txt"
cmp "$TMP/expect-tok.txt" "$TMP/out-tok.txt" || fail tunnel-output
grep -q 'vless://' "$TMP/out-tok.txt" && fail tunnel-showed-vless
grep -q 'qrencode\|二维码' "$TMP/out-tok.txt" && fail tunnel-showed-qr-text
[ ! -s "$QRLOG" ] || fail tunnel-called-qr
[ ! -s "$TMP/err-tok.txt" ] || fail tunnel-extra-stderr
grep -q '^open ' "$TMP/fwlog2" && fail tunnel-ok-opened
grep -q 'restart xray' "$SYSLOG" && fail restarted-xray
grep -q 'restart reality-sub' "$SYSLOG" || fail sub-service
now=$(md5sum "$CONF" | awk '{print $1}')
[ "$now" = "$before" ] || fail tunnel-ok-changed-config
[ ! -s "$XLOG" ] || fail tunnel-ok-called-xray
MOCK_JOURNAL='new hostname https://beta-fake.trycloudflare.com ready'
sync_tunnel_url || fail sync
write_sub_url_file || fail rewrite
newurl='https://beta-fake.trycloudflare.com/fakepath0123456789abcdef0123456789ab'
[ "$(cat "$SUBURLF")" = "$newurl" ] || fail synced-url
grep -q 'alpha-fake' "$SUBURLF" && fail stale-url-remains
ok tunnel-ok-and-sync

fresh
export PATH="$BIN:$ORIG_PATH"
printf '%s\n' \
  'IP=203.0.113.10' \
  'SUBPORT=38921' \
  'SUBPATH=fakepath0123456789abcdef0123456789ab' \
  'BIND=127.0.0.1' \
  'TUNNEL=1' \
  'TUNNEL_URL=https://alpha-fake.trycloudflare.com' \
  > "$SUBENV"
printf '%s\n' 'https://alpha-fake.trycloudflare.com/fakepath0123456789abcdef0123456789ab' > "$SUBURLF"
export MOCK_TUNNEL_ACTIVE=0
export MOCK_JOURNAL=''
systemd_booted() { return 0; }
rc=0
sub_show >"$TMP/out-down.txt" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail down-tunnel-succeeded
[ -f "$SUBURLF" ] && fail down-tunnel-kept-stale
grep -q 'alpha-fake' "$TMP/out-down.txt" && fail down-tunnel-printed-stale
ok tunnel-down-hides-stale

fresh
export PATH="$ORIG_PATH"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$TMP/qr"
chmod 755 "$TMP/qr"
export PATH="$TMP:$ORIG_PATH"
mkdir -p "$SUBDIR"
printf '%s\n' \
  'IP=203.0.113.10' \
  'SUBPORT=38921' \
  'SUBPATH=fakepath0123456789abcdef0123456789ab' \
  'BIND=0.0.0.0' \
  'TUNNEL=0' \
  'TUNNEL_URL=' \
  > "$SUBENV"
write_xray_config "$CONF" 443 dest.example.com 11111111-1111-4111-8111-111111111111 fictional-private-key fictional-sid 0 0
printf 'fictional-public-key\n' > "$PUBF"
systemd_booted() { return 1; }
start_cloudflare_tunnel() { echo started >> "$TMP/started"; return 1; }
fw_open_tcp() { echo "open $1" >> "$TMP/fwlog3"; }
: > "$TMP/fwlog3"
SUB_TUNNEL=0
sub_enable >"$TMP/out-http.txt" 2>"$TMP/err-http.txt" || fail explicit-http
url='http://203.0.113.10:38921/fakepath0123456789abcdef0123456789ab'
[ "$(cat "$SUBURLF")" = "$url" ] || fail http-url
grep -q '明文 HTTP' "$TMP/err-http.txt" || fail http-explicit
grep -q '不是 HTTPS' "$TMP/err-http.txt" || fail http-not-https
printf '%s\n%s\n' "$SUBURLF" "$url" > "$TMP/expect-http.txt"
cmp "$TMP/expect-http.txt" "$TMP/out-http.txt" || fail http-output
grep -q 'vless://' "$TMP/out-http.txt" && fail http-showed-vless
[ -f "$TMP/started" ] && fail http-started-tunnel
grep -q '^open 38921$' "$TMP/fwlog3" || fail http-fw
ok explicit-http

fresh
export PATH="$ORIG_PATH"
mkdir -p "$SUBDIR"
printf '%s\n' \
  'IP=203.0.113.10' \
  'SUBPORT=9' \
  'SUBPATH=fakepath0123456789abcdef0123456789ab' \
  'BIND=127.0.0.1' \
  'TUNNEL=1' \
  'TUNNEL_URL=' \
  > "$SUBENV"
rc=0
sub_url >"$TMP/out-empty-url.txt" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail empty-tunnel-url
grep -q 'http://' "$TMP/out-empty-url.txt" && fail empty-tunnel-became-http
ok empty-tunnel-url

fresh
export PATH="$ORIG_PATH"
write_xray_config "$CONF" 443 dest.example.com 11111111-1111-4111-8111-111111111111 fictional-private-key fictional-sid 0 0
printf 'fictional-public-key\n' > "$PUBF"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
mkdir -p "$SUBDIR"
printf '%s\n' \
  "IP=203.0.113.10" \
  "SUBPORT=$port" \
  'SUBPATH=fakepath0123456789abcdef0123456789ab' \
  'BIND=127.0.0.1' \
  'TUNNEL=0' \
  'TUNNEL_URL=' \
  > "$SUBENV"
write_sub_server
REALITY_SUBENV="$SUBENV" REALITY_XRAY_CONF="$CONF" REALITY_PUBF="$PUBF" REALITY_LINKF="$LINKF" \
  python3 "$SUBPY" >"$TMP/sub.out" 2>"$TMP/sub.err" &
spid=$!
body=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if body=$(curl -fsS -A 'okhttp/4.12.0' "http://127.0.0.1:${port}/fakepath0123456789abcdef0123456789ab" 2>/dev/null); then
    break
  fi
  sleep 0.2
done
clash=$(curl -fsS -A 'okhttp/4.12.0' "http://127.0.0.1:${port}/fakepath0123456789abcdef0123456789ab?target=clash" || true)
fl=$(curl -fsS -A 'FlClash/9.9.9' "http://127.0.0.1:${port}/fakepath0123456789abcdef0123456789ab" || true)
kill "$spid" 2>/dev/null || true
wait "$spid" 2>/dev/null || true
[ -n "$body" ] || { cat "$TMP/sub.err" >&2; fail sub-http; }
decoded=$(printf '%s' "$body" | base64 -d)
printf '%s\n' "$decoded" | grep -q '^vless://' || fail ua-not-base64
printf '%s\n' "$decoded" | grep -q '11111111-1111-4111-8111-111111111111' || fail ua-uuid
printf '%s\n' "$clash" | grep -q 'type: vless' || fail target-clash-type
printf '%s\n' "$clash" | grep -q 'reality-opts:' || fail target-clash-reality
printf '%s\n' "$clash" | grep -q 'client-fingerprint: chrome' || fail target-clash-fp
printf '%s\n' "$clash" | grep -q 'fictional-public-key' || fail target-clash-key
printf '%s\n' "$fl" | grep -q 'type: vless' || fail flclash-ua
ok sub-formats

fresh
export PATH="$ORIG_PATH"
printf '%s\n' '{"inbounds":[]}' > "$CONF"
rm -f "$SUBENV"
sub_enable() { printf '%s\n' "${SUB_TUNNEL:-unset}" > "$TMP/menu-tunnel"; return 0; }
printf '\n' | enable_subscription_from_menu >"$TMP/out-menu.txt" || fail menu-default
[ "$(cat "$TMP/menu-tunnel")" = 1 ] || fail menu-default-tunnel
unset SUB_TUNNEL
printf 'n\n' | enable_subscription_from_menu >"$TMP/out-menu-n.txt" || fail menu-no
[ "$(cat "$TMP/menu-tunnel")" = 0 ] || fail menu-no-tunnel
mkdir -p "$SUBDIR"
printf '%s\n' 'TUNNEL=1' > "$SUBENV"
sub_enable() { echo synced > "$TMP/menu-sync"; return 0; }
enable_subscription_from_menu </dev/null >"$TMP/out-menu-sync.txt" || fail menu-sync
[ "$(cat "$TMP/menu-sync")" = synced ] || fail menu-sync-skipped-prompt
grep -q '不重启 Xray' "$TMP/out-menu-sync.txt" || fail menu-sync-copy
ok menu-option

fresh
export PATH="$ORIG_PATH"
write_fake_xray
export XLOG=$TMP/xlog3
: > "$XLOG"
AUTO=1
SUBSCRIPTION=0
FAIL2BAN=0
HYSTERIA2=0
DISABLE_SSH_PASSWORD=0
PORT=443
SNI=dest.example.com
unset SUB_TUNNEL || true
ensure_install_deps() { echo ensure >> "$TMP/deploy.log"; return 0; }
install_xray() { echo "install_xray $1" >> "$TMP/deploy.log"; return 0; }
sub_enable() { echo sub >> "$TMP/deploy.log"; return 1; }
enable_bbr() { return 0; }
fw_open_tcp() { return 0; }
get_ip() { printf '%s\n' '203.0.113.10'; }
systemd_booted() { return 1; }
setup_fail2ban() { echo f2b >> "$TMP/deploy.log"; return 0; }
setup_hysteria() { return 0; }
setup_ssh_password() { return 0; }
: > "$TMP/deploy.log"
deploy >"$TMP/out-deploy0.txt" 2>"$TMP/err-deploy0.txt" || fail reality-only
grep -q '^ensure$' "$TMP/deploy.log" || fail deploy-ensure
grep -q '^install_xray v26.7.28$' "$TMP/deploy.log" || fail deploy-xray
grep -q '^sub$' "$TMP/deploy.log" && fail deploy-called-sub
grep -q '没有订阅' "$TMP/err-deploy0.txt" || fail deploy-sub-off-msg
grep -q '未生成订阅 URL' "$TMP/err-deploy0.txt" || fail deploy-no-url-msg
grep -q 'vless://' "$TMP/out-deploy0.txt" && fail deploy-showed-vless
grep -q 'https://' "$TMP/out-deploy0.txt" && fail deploy-fake-https
grep -q 'vless://' "$LINKF" || fail deploy-link
grep -q 'fictional-public-key' "$LINKF" || fail deploy-pub
[ -f "$SUBURLF" ] && fail deploy-wrote-sub-url
finish_install 0 || fail finish-ok
rc=0
finish_install 1 || rc=$?
[ "$rc" -ne 0 ] || fail finish-hides-failure
ok reality-only-install

fresh
export PATH="$ORIG_PATH"
write_fake_xray
AUTO=1
unset SUBSCRIPTION SUB_TUNNEL || true
FAIL2BAN=0
HYSTERIA2=0
DISABLE_SSH_PASSWORD=0
PORT=443
SNI=dest.example.com
ensure_install_deps() { return 0; }
install_xray() { return 0; }
sub_enable() { echo sub-failed >> "$TMP/deploy2.log"; return 1; }
enable_bbr() { return 0; }
fw_open_tcp() { return 0; }
get_ip() { printf '%s\n' '203.0.113.10'; }
systemd_booted() { return 1; }
setup_fail2ban() { return 0; }
setup_hysteria() { return 0; }
setup_ssh_password() { return 0; }
: > "$TMP/deploy2.log"
rc=0
deploy >"$TMP/out-deploy1.txt" 2>"$TMP/err-deploy1.txt" || rc=$?
[ "$rc" -ne 0 ] || fail sub-fail-reported-success
grep -q sub-failed "$TMP/deploy2.log" || fail sub-not-attempted
grep -q 'HTTPS 订阅未就绪' "$TMP/err-deploy1.txt" || fail sub-fail-message
grep -q '没有可用的订阅 URL' "$TMP/err-deploy1.txt" || fail sub-fail-no-url
grep -q 'vless://' "$TMP/out-deploy1.txt" && fail sub-fail-showed-vless
grep -q 'http://' "$TMP/out-deploy1.txt" && fail sub-fail-showed-http
grep -q '11111111-1111-4111-8111-111111111111' "$CONF" || fail sub-fail-lost-reality
rc=0
finish_install 1 || rc=$?
[ "$rc" -ne 0 ] || fail install-exit-would-succeed
ok install-sub-failure

fresh
export PATH="$ORIG_PATH"
printf '%s\n' 'vless://11111111-1111-4111-8111-111111111111@203.0.113.10:443?encryption=none#fictional' > "$LINKF"
rm -f "$SUBENV"
export QRLOG=$TMP/qrlog-menu
: > "$QRLOG"
mkdir -p "$TMP/bin-menu"
cat > "$TMP/bin-menu/qrencode" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$QRLOG"
exit 0
EOF
chmod 755 "$TMP/bin-menu/qrencode"
export PATH="$TMP/bin-menu:$ORIG_PATH"
systemd_booted() { return 1; }
show_link >"$TMP/out-show.txt" || fail show-link
grep -q 'vless://11111111-1111-4111-8111-111111111111@203.0.113.10:443' "$TMP/out-show.txt" || fail show-link-vless
grep -q '单节点 vless' "$TMP/out-show.txt" || fail show-link-label
[ -s "$QRLOG" ] || fail show-link-qr
ok menu-node-qr

export PATH="$ORIG_PATH"
if command -v shellcheck >/dev/null 2>&1; then
  # SC2034: path and install variables are consumed by the sourced script.
  shellcheck -S warning "$ROOT/reality-menu.sh"
  shellcheck -S warning -e SC2034 "$ROOT/tests/apt-and-sub.sh"
  ok shellcheck
fi

echo "apt-and-sub passed"
