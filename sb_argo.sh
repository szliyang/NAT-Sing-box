#!/bin/bash
# =========================================
# sing-box 单端口 NAT 版: vless-reality(TCP) + tuic(UDP) 同端口 + vmess-ws 走 Argo 隧道
# 免 root, 容器/翼龙友好: 自动读取 PTERODACTYL/SERVER_PORT 环境变量
# 端口优先级: PORT > PTERODACTYL_SERVER_PORT > SERVER_PORT > 随机
# 20261011-xxxx init: 基于 sb 系列, 单端口布局(TCP+UDP 同号), vmess-ws 交 Argo 不占本地端口
# =========================================
set -euo pipefail
export LC_ALL=C

MASQ_DOMAIN="www.iij.ad.jp"     # vless-reality 伪装站点
TUIC_SNI="www.bing.com"         # tuic 自签证书 SNI
CONF_JSON="sb-argo.json"
CERT_PEM="sb-cert.pem"
KEY_PEM="sb-key.pem"
LINK_TXT="sb_argo_link.txt"
SB_BIN="./sing-box"
CFD_BIN="./cloudflared"
ARGO_LOCAL_PORT="${ARGO_PORT:-8001}"

# ========== 端口自动获取 ==========
detect_port() {
  if [[ -n "${PORT:-}" ]]; then
    echo "$PORT"
  elif [[ -n "${PTERODACTYL_SERVER_PORT:-}" ]]; then
    echo "$PTERODACTYL_SERVER_PORT"
  elif [[ -n "${SERVER_PORT:-}" ]]; then
    echo "$SERVER_PORT"
  else
    shuf -i 10000-65535 -n 1
  fi
}

get_server_ip() {
  [[ -n "${PTERODACTYL_SERVER_IP:-}" ]] && { echo "$PTERODACTYL_SERVER_IP"; return; }
  [[ -n "${SERVER_IP:-}" ]] && { echo "$SERVER_IP"; return; }
  curl -4 -sm 5 https://api.ipify.org || echo "127.0.0.1"
}

# ========== 架构与下载 ==========
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7|armv7l) echo "armv7" ;;
    *) echo ""; red "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}

red()    { echo -e "\e[1;91m$1\033[0m"; }
green()  { echo -e "\e[1;32m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }

download_bins() {
  local arch
  arch=$(detect_arch)
  if [[ ! -x "$SB_BIN" ]]; then
    echo "📥 Downloading sing-box (${arch})..."
    curl -sL -o sb.tgz "https://github.com/SagerNet/sing-box/releases/download/v1.10.7/sing-box-1.10.7-linux-${arch}.tar.gz"
    tar xzf sb.tgz "sing-box-1.10.7-linux-${arch}/sing-box" --strip-components=1
    rm -f sb.tgz && chmod +x "$SB_BIN"
  else
    green "✅ sing-box 已存在"
  fi
  if [[ ! -x "$CFD_BIN" ]]; then
    echo "📥 Downloading cloudflared (${arch})..."
    curl -sL -o "$CFD_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    chmod +x "$CFD_BIN"
  else
    green "✅ cloudflared 已存在"
  fi
}

# ========== 证书(vless 不需要, tuic 自签) ==========
generate_cert() {
  [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]] && { green "🔐 证书已存在"; return; }
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${TUIC_SNI}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM"; chmod 644 "$CERT_PEM"
}

# ========== 生成配置 ==========
generate_config() {
  cat > "$CONF_JSON" <<EOF
{
  "log": {"level": "warn"},
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": ${PORT},
      "users": [{"uuid": "${UUID}", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "${MASQ_DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": {"server": "${MASQ_DOMAIN}", "server_port": 443},
          "private_key": "${REALITY_PRIV}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "0.0.0.0",
      "listen_port": ${PORT},
      "users": [{"uuid": "${UUID}", "password": "${TUIC_PASS}"}],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${CERT_PEM}",
        "key_path": "${KEY_PEM}"
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "127.0.0.1",
      "listen_port": ${ARGO_LOCAL_PORT},
      "users": [{"uuid": "${UUID}", "alterId": 0}],
      "transport": {
        "type": "ws",
        "path": "/vmess-argo"
      }
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
}

# ========== Argo 隧道 ==========
start_argo() {
  if [[ -n "${ARGO_AUTH:-}" && -n "${ARGO_DOMAIN:-}" ]]; then
    nohup "$CFD_BIN" tunnel run --token "$ARGO_AUTH" >/dev/null 2>&1 &
    green "✅ Argo 隧道(token)已启动: ${ARGO_DOMAIN}"
    ARGO_HOST="$ARGO_DOMAIN"
  else
    nohup "$CFD_BIN" tunnel --url "http://127.0.0.1:${ARGO_LOCAL_PORT}" \
      --no-autoupdate --protocol http2 --logfile argo.log --loglevel info >/dev/null 2>&1 &
    # 临时隧道域名需要等几秒从日志里取
    local i
    for i in $(seq 1 30); do
      ARGO_HOST=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' argo.log 2>/dev/null | head -n1 | sed 's#https://##')
      [[ -n "$ARGO_HOST" ]] && break
      sleep 1
    done
    if [[ -n "${ARGO_HOST:-}" ]]; then
      green "✅ Argo 临时隧道已启动: ${ARGO_HOST}"
    else
      red "⚠️ Argo 临时隧道域名获取失败(不影响 vless/tuic), 可查看 argo.log"
      ARGO_HOST="argodomain.pending"
    fi
  fi
}

# ========== 生成链接 ==========
generate_links() {
  local ip="$1"
  cat > "$LINK_TXT" <<EOF
vless://${UUID}@${ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${MASQ_DOMAIN}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp&headerType=none#sbargo-vless
tuic://${UUID}:${TUIC_PASS}@${ip}:${PORT}?sni=${TUIC_SNI}&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#sbargo-tuic
vmess://$(echo "{ \"v\": \"2\", \"ps\": \"sbargo-vmess\", \"add\": \"${CFIP:-${ARGO_HOST}}\", \"port\": \"${CFPORT:-443}\", \"id\": \"${UUID}\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${ARGO_HOST}\", \"path\": \"/vmess-argo?ed=2048\", \"tls\": \"tls\", \"sni\": \"${ARGO_HOST}\", \"alpn\": \"\", \"fp\": \"\"}" | base64 -w0)
EOF
  purple "🔗 节点链接已生成:"
  cat "$LINK_TXT"
}

# ========== 守护 ==========
run_loop() {
  echo "🚀 Starting sing-box (vless+tuic on :${PORT})..."
  while true; do
    "$SB_BIN" run -c "$CONF_JSON" >/dev/null 2>&1 || true
    echo "⚠️ sing-box crashed. Restarting in 5s..."
    sleep 5
  done
}

# ========== 主流程 ==========
main() {
  PORT=$(detect_port)
  echo "✅ 端口: ${PORT} (vless=TCP, tuic=UDP, 同端口)"
  UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
  TUIC_PASS="$(openssl rand -hex 16)"
  local keys=$("$SB_BIN" generate reality-keypair)
  REALITY_PRIV=$(echo "$keys" | awk '/PrivateKey/{print $2}')
  REALITY_PUB=$(echo "$keys" | awk '/PublicKey/{print $2}')
  SHORT_ID=$(openssl rand -hex 4)
  generate_cert
  generate_config
  start_argo
  ip="$(get_server_ip)"
  generate_links "$ip"
  run_loop
}

download_bins
main
