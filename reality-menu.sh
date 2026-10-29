#!/usr/bin/env bash
# 梯哥 VLESS + Reality 管理菜单（基于 XTLS 官方安装脚本）
# 用法：root 执行  bash reality-menu.sh
CONF=/usr/local/etc/xray/config.json
LINKF=/root/reality-link.txt
OFFICIAL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }

need(){ command -v "$1" >/dev/null || apt-get install -y "$1" >/dev/null 2>&1 || yum install -y "$1" >/dev/null 2>&1; }

show_link(){
  [ -f "$LINKF" ] || { echo "没有找到 $LINKF（可能不是用本脚本部署的）"; return; }
  echo; cat "$LINKF"; echo
  need qrencode; command -v qrencode >/dev/null && qrencode -t ansiutf8 "$(cat $LINKF)"
}

deploy(){
  read -rp "端口 [443]: " PORT; PORT=${PORT:-443}
  read -rp "伪装域名 [www.apple.com]: " SNI; SNI=${SNI:-www.apple.com}
  if [ -f "$CONF" ]; then
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
  echo "== 部署完成 =="; show_link
  echo "云服务商若有安全组，记得放行 $PORT/TCP"
}

while true; do
  echo
  echo "====== 梯哥 Reality 管理 ======"
  echo " 1. 安装 / 重装（生成新链接）"
  echo " 2. 查看导入链接和二维码"
  echo " 3. 查看运行状态"
  echo " 4. 查看最近日志"
  echo " 5. 重启服务"
  echo " 6. 更新 Xray（配置不变）"
  echo " 7. 卸载"
  echo " 0. 退出"
  read -rp "请选择: " c
  case $c in
    1) deploy ;;
    2) show_link ;;
    3) systemctl status xray --no-pager ;;
    4) journalctl -u xray -n 50 --no-pager ;;
    5) systemctl restart xray && echo "已重启" ;;
    6) bash -c "$(curl -L $OFFICIAL)" @ install && systemctl restart xray ;;
    7) read -rp "确定卸载并删除配置？(y/N) " a; [ "$a" = y ] && bash -c "$(curl -L $OFFICIAL)" @ remove --purge && rm -f "$LINKF" ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done
