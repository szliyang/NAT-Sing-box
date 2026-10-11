#!/bin/bash
# =========================================
# sing-box 单端口 NAT 版: vless-reality(TCP) + tuic(UDP) 同端口 + vmess-ws 走 Argo 隧道
# 免 root, 容器/翼龙友好: 自动读取 PTERODACTYL/SERVER_PORT 环境变量
# 端口优先级: PORT > PTERODACTYL_SERVER_PORT > SERVER_PORT > 随机
#
# 用法(任选其一):
#   1) bash <(curl -Ls https://raw.githubusercontent.com/szliyang/NAT-sing-box/main/sb_argo.sh)
#   2) curl -Ls "https://raw.githubusercontent.com/szliyang/NAT-sing-box/main/sb_argo.sh?t=$(date +%s)" | bash
#   3) bash sb_argo.sh          # 自举落地后本地直接运行, 断网也能跑
#   4) bash sb_argo.sh --diag   # 部署并运行节点, 启动约 2 分钟后自动生成 00diag.txt 诊断报告
#   5) bash sb_argo.sh renew    # 删旧配置全新开始(停旧进程+清凭据/配置/证书/链接/日志, 二进制保留)
#
# 自举(NAT 机免 crontab):
#   - 脚本自身 + 依赖(sing-box/cloudflared) + 凭据 全部落地工作目录
#   - 凭据持久化在 sb_argo.env, 重启后复用, 节点链接不变
#   - sing-box 前台 while-true 守护; cloudflared 后台循环守护, 挂掉自动重启并刷新链接
#   - 容器/主机重启后执行: bash sb_argo.sh
# 20261011-xxxx init: 基于 sb 系列, 单端口布局(TCP+UDP 同号), vmess-ws 交 Argo 不占本地端口
# 20261011-1602 feat: 自举 — 管道执行自动落地脚本+依赖, 凭据持久化复用(链接不变), cloudflared 纳入守护, verbose 输出
# 20261011-1616 fix: vmess-ws 入站补 max_early_data/early_data_header_name(否则 ?ed=2048 客户端 bad request), 链接 scy=none 对齐 sb 系列
# 20261011-1616 feat: 全量运行日志 sb-run.log; --diag 自检报告(连通性探测+凭据一致性核对+配置/日志汇总)
# 20261011-1705 fix: 多源下载(直连->ghproxy 镜像)防墙内自更新失败; 版本号 SELF_VER 落日志/diag; diag 增加 early-data 修复生效检测
# 20261011-1724 fix: cloudflared 存活检测改 pidfile+kill -0(容器无 pgrep 曾致每 30s 误重启换域名); 自检 101 前缀匹配; diag 进程段改 /proc 扫描
# 20261011-1727 feat: 启动时外部命令依赖自检(必需缺失即退出, 可选报告备选); seq 改 bash 内建循环; diag 增命令清单段
# 20261011-1733 feat: renew 参数 — 停旧进程+清凭据/配置/证书/链接/日志, 全新部署(节点链接全部更换)
# 20261011-1758 feat: tuic 诊断 — 本地回环自测(sing-box 自身当客户端), 后台每 60s 采样内核 UDP 计数/负载, diag 增 UDP 专检
# 20261011-1810 feat: --diag 改为"部署+运行+自动采集"一条龙, 报告固定写 00diag.txt(启动约 2 分钟后生成, 节点持续运行)
# 20261011-1815 feat: 节点链接文件改名 00links.txt(与 00diag.txt 同前缀, 排序靠前便于下载查看)
# =========================================
set -euo pipefail
export LC_ALL=C

SELF_VER="20261011-1815"
WORKDIR="$(pwd)"                 # 管道执行时无脚本目录, 统一用当前目录
SELF_FILE="${WORKDIR}/sb_argo.sh"
CONF_JSON="${WORKDIR}/sb-argo.json"
ENV_FILE="${WORKDIR}/sb_argo.env"
CERT_PEM="${WORKDIR}/sb-cert.pem"
KEY_PEM="${WORKDIR}/sb-key.pem"
LINK_TXT="${WORKDIR}/00links.txt"
SB_BIN="${WORKDIR}/sing-box"
CFD_BIN="${WORKDIR}/cloudflared"
ARGO_LOG="${WORKDIR}/argo.log"
ARGO_PID_FILE="${WORKDIR}/argo.pid"
UDP_STATS_LOG="${WORKDIR}/sb-udp-stats.log"
RUN_LOG="${WORKDIR}/sb-run.log"
DIAG_TXT="${WORKDIR}/00diag.txt"
RAW_BASE="https://raw.githubusercontent.com/szliyang/NAT-sing-box/main"
SB_VER="1.10.7"
ARGO_LOCAL_PORT="${ARGO_PORT:-8001}"
MASQ_DOMAIN="www.iij.ad.jp"      # vless-reality 伪装站点
TUIC_SNI="www.bing.com"          # tuic 自签证书 SNI

red()    { echo -e "\033[1;91m$1\033[0m"; }
green()  { echo -e "\033[1;32m$1\033[0m"; }
purple() { echo -e "\033[1;35m$1\033[0m"; }

# ========== 端口: 只认显式环境变量, 随机值不参与凭据恢复 ==========
ENV_PORT=""                      # 显式指定的端口(可空)
PORT_SRC=""
detect_port() {
  if [[ -n "${PORT:-}" ]]; then ENV_PORT="$PORT"; PORT_SRC="PORT"
  elif [[ -n "${PTERODACTYL_SERVER_PORT:-}" ]]; then ENV_PORT="$PTERODACTYL_SERVER_PORT"; PORT_SRC="PTERODACTYL_SERVER_PORT"
  elif [[ -n "${SERVER_PORT:-}" ]]; then ENV_PORT="$SERVER_PORT"; PORT_SRC="SERVER_PORT"
  else ENV_PORT=""; PORT_SRC="随机"
  fi
}

get_server_ip() {
  [[ -n "${PTERODACTYL_SERVER_IP:-}" ]] && { echo "$PTERODACTYL_SERVER_IP"; return; }
  [[ -n "${SERVER_IP:-}" ]] && { echo "$SERVER_IP"; return; }
  local ip; ip="$(curl -4 -sm 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] && { echo "$ip"; return; }
  # 断网回退: 沿用链接文件里上次的 IP, 避免降级成 127.0.0.1 覆盖已有链接
  if [[ -s "$LINK_TXT" ]]; then
    ip="$(sed -n 's#^vless://[^@]*@\([^:]*\):.*#\1#p' "$LINK_TXT" | head -n1)"
    [[ -n "$ip" ]] && { echo "$ip"; return; }
  fi
  echo "127.0.0.1"
}

# ========== 架构 ==========
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7|armv7l) echo "armv7" ;;
    *) echo ""; red "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}

# ========== 多源下载: 直连失败自动走 ghproxy 镜像(墙内 NAT 机 GitHub 常不可达) ==========
mirror_urls() {
  echo "$1"
  case "$1" in
    https://raw.githubusercontent.com/*|https://github.com/*|https://objects.githubusercontent.com/*)
      echo "https://ghproxy.net/$1"
      echo "https://gh-proxy.com/$1"
      ;;
  esac
}

fetch() {  # fetch <url> <dest>: 依次尝试直连/镜像, 全部失败返回 1
  local url="$1" dest="$2" u rc first=1
  for u in $(mirror_urls "$url"); do
    [[ $first -eq 0 ]] && echo "   ↪️ [镜像] ${u}"
    first=0
    rc=0
    curl -fL --connect-timeout 15 --retry 1 -o "$dest" "$u" || rc=$?
    if [[ $rc -eq 0 && -s "$dest" ]]; then return 0; fi
    rm -f "$dest"
  done
  return 1
}

# ========== 启动依赖自检: 外部命令缺失早报告, 不等到运行中才炸 ==========
check_deps() {
  local fatal=0 opt="" cmd
  for cmd in curl tar openssl base64 tee awk sed grep tr cmp wc uname nohup sleep date cat; do
    command -v "$cmd" >/dev/null 2>&1 || { red "❌ [依赖] 缺少必需命令: ${cmd}"; fatal=1; }
  done
  command -v shuf >/dev/null 2>&1 || opt="${opt} shuf(备选:RANDOM)"
  if [[ ! -r /proc/sys/kernel/random/uuid ]] && ! command -v uuidgen >/dev/null 2>&1; then
    red "❌ [依赖] 无法生成 UUID(/proc/sys/kernel/random/uuid 与 uuidgen 均不可用)"
    fatal=1
  fi
  command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 \
    || opt="${opt} ss/netstat(仅影响 --diag 端口展示)"
  if [[ $fatal -eq 1 ]]; then
    red "❌ [依赖] 必需命令缺失, 无法继续; 精简容器请换基础镜像或安装 coreutils/procps"
    exit 1
  fi
  [[ -n "$opt" ]] && echo "⚠️ [依赖] 可选命令缺失(已有备选):${opt}"
  green "✅ [依赖] 外部命令自检通过"
}

# ========== 自举1: 脚本自身落地(管道执行时本地没有本文件) ==========
ensure_self() {
  echo "📥 [自举] 拉取脚本自身: ${RAW_BASE}/sb_argo.sh (直连失败自动切镜像)"
  if ! fetch "${RAW_BASE}/sb_argo.sh?t=$(date +%s)" "${SELF_FILE}.tmp"; then
    rm -f "${SELF_FILE}.tmp"
    if [[ -s "$SELF_FILE" ]]; then
      echo "⚠️ [自举] 脚本下载失败(直连+镜像均不通), 沿用本地版本: ${SELF_FILE}"
    else
      red "⚠️ [自举] 脚本下载失败(直连+镜像均不通), 本次以管道副本运行; 建议将脚本手动保存到 ${SELF_FILE}"
    fi
    return 0
  fi
  if [[ -s "$SELF_FILE" ]] && cmp -s "${SELF_FILE}.tmp" "$SELF_FILE"; then
    rm -f "${SELF_FILE}.tmp"
    green "✅ [自举] 脚本已是最新: ${SELF_FILE} ($(wc -c < "$SELF_FILE" | tr -d ' ') bytes)"
  else
    mv "${SELF_FILE}.tmp" "$SELF_FILE"
    chmod +x "$SELF_FILE" || true
    green "✅ [自举] 脚本已落地/更新: ${SELF_FILE} ($(wc -c < "$SELF_FILE" | tr -d ' ') bytes, 更新下次运行生效)"
  fi
}

# ========== 自举2: 依赖落地(sing-box 必需, cloudflared 可选) ==========
download_bins() {
  local arch; arch="$(detect_arch)"
  echo "🖥️  [依赖] 架构: $(uname -m) -> ${arch}"

  if [[ -x "$SB_BIN" ]]; then
    green "✅ [依赖] sing-box 已存在: $("$SB_BIN" version 2>/dev/null | head -n1)"
  else
    local url="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${arch}.tar.gz"
    echo "📥 [依赖] 下载 sing-box v${SB_VER}: ${url}"
    if ! fetch "$url" "${WORKDIR}/sb.tgz"; then
      rm -f "${WORKDIR}/sb.tgz"
      red "❌ [依赖] sing-box 下载失败(直连+镜像均不通), 本地亦无旧版可回退"
      red "   手动诊断: curl -v ${url} -o /dev/null"
      exit 1
    fi
    tar xzf "${WORKDIR}/sb.tgz" -C "$WORKDIR" --strip-components=1 "sing-box-${SB_VER}-linux-${arch}/sing-box"
    rm -f "${WORKDIR}/sb.tgz"
    chmod +x "$SB_BIN"
    green "✅ [依赖] sing-box 落地: ${SB_BIN} ($("$SB_BIN" version 2>/dev/null | head -n1))"
  fi

  if [[ -x "$CFD_BIN" ]]; then
    green "✅ [依赖] cloudflared 已存在: ${CFD_BIN}"
  else
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    echo "📥 [依赖] 下载 cloudflared: ${url}"
    if ! fetch "$url" "${CFD_BIN}.tmp"; then
      rm -f "${CFD_BIN}.tmp"
      red "⚠️ [依赖] cloudflared 下载失败(直连+镜像均不通), 跳过 Argo 隧道(不影响 vless/tuic)"
      CFD_BIN=""
      return 0
    fi
    mv "${CFD_BIN}.tmp" "$CFD_BIN"
    chmod +x "$CFD_BIN"
    green "✅ [依赖] cloudflared 落地: ${CFD_BIN} ($(wc -c < "$CFD_BIN" | tr -d ' ') bytes)"
  fi
}

# ========== 自举3: 凭据持久化(重启复用, 节点链接不变) ==========
save_env() {
  cat > "$ENV_FILE" <<EOF
# sb_argo 凭据持久化(自举复用, 勿外传)
SB_PORT=${PORT}
SB_UUID=${UUID}
SB_TUIC_PASS=${TUIC_PASS}
SB_REALITY_PRIV=${REALITY_PRIV}
SB_REALITY_PUB=${REALITY_PUB}
SB_SHORT_ID=${SHORT_ID}
EOF
  chmod 600 "$ENV_FILE" || true
}

load_credentials() {
  if [[ -s "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    if [[ -n "$ENV_PORT" && "$ENV_PORT" != "$SB_PORT" ]]; then
      echo "⚠️ [凭据] 端口变化: ${SB_PORT} -> ${ENV_PORT} (来源 ${PORT_SRC}), 以环境变量为准"
      SB_PORT="$ENV_PORT"
    fi
    PORT="$SB_PORT"; UUID="$SB_UUID"; TUIC_PASS="$SB_TUIC_PASS"
    REALITY_PRIV="$SB_REALITY_PRIV"; REALITY_PUB="$SB_REALITY_PUB"; SHORT_ID="$SB_SHORT_ID"
    save_env
    green "✅ [凭据] 复用 ${ENV_FILE} 已有凭据, 重启后节点链接不变"
    echo "    PORT=${PORT} UUID=${UUID:0:8}... SHORT_ID=${SHORT_ID} TUIC_PASS=${TUIC_PASS:0:6}... pbk=${REALITY_PUB:0:8}..."
  else
    PORT="${ENV_PORT:-$(shuf -i 10000-65535 -n 1 2>/dev/null || echo $((RANDOM % 40000 + 20000)))}"
    UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
    TUIC_PASS="$(openssl rand -hex 16)"
    local keys; keys="$("$SB_BIN" generate reality-keypair)"
    REALITY_PRIV="$(echo "$keys" | awk '/PrivateKey/{print $2}')"
    REALITY_PUB="$(echo "$keys" | awk '/PublicKey/{print $2}')"
    SHORT_ID="$(openssl rand -hex 4)"
    save_env
    green "✅ [凭据] 首次部署, 凭据已生成并持久化到 ${ENV_FILE} (权限 600)"
  fi
}

# ========== 证书(vless 不需要, tuic 自签) ==========
generate_cert() {
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    green "🔐 [证书] 已存在, 复用"
    return
  fi
  echo "🔐 [证书] 生成 tuic 自签证书 (CN=${TUIC_SNI}, 365d)"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${TUIC_SNI}" -days 365 -nodes >/dev/null 2>&1
  chmod 600 "$KEY_PEM" || true; chmod 644 "$CERT_PEM" || true
}

# ========== 生成配置 ==========
generate_config() {
  echo "📝 [配置] 生成 ${CONF_JSON} (vless+tuic :${PORT}, vmess-ws 127.0.0.1:${ARGO_LOCAL_PORT})"
  cat > "$CONF_JSON" <<EOF
{
  "log": {"level": "info", "timestamp": true},
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
        "path": "/vmess-argo",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
}

# ========== Argo 隧道(存活检测用 pidfile+kill -0, 不依赖 pgrep) ==========
ARGO_HOST=""
cfd_pid() { [[ -s "$ARGO_PID_FILE" ]] && cat "$ARGO_PID_FILE" 2>/dev/null || true; }

cfd_alive() {
  local p; p="$(cfd_pid)"
  [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null
}

kill_stray_cfd() {  # 清理旧版本残留的无 pidfile 记录的 cloudflared
  [[ -d /proc ]] || return 0
  local p cmd
  for p in /proc/[0-9]*/cmdline; do
    cmd="$(tr '\0' ' ' < "$p" 2>/dev/null || true)"
    case "$cmd" in
      *"$CFD_BIN"*) kill "${p#/proc/}" 2>/dev/null || true ;;
    esac
  done
}

argo_start() {
  if [[ -z "$CFD_BIN" ]]; then
    ARGO_HOST="argodomain.pending"
    return 0
  fi
  if cfd_alive; then
    echo "ℹ️  [Argo] cloudflared 已在运行(pid $(cfd_pid)), 不重复启动"
    [[ -z "${ARGO_HOST:-}" ]] && ARGO_HOST="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$ARGO_LOG" 2>/dev/null | tail -n1 | sed 's#https://##' || true)"
    return 0
  fi
  kill_stray_cfd
  rm -f "$ARGO_LOG"                       # 清旧日志, 避免取到上次的临时域名
  if [[ -n "${ARGO_AUTH:-}" && -n "${ARGO_DOMAIN:-}" ]]; then
    echo "🌐 [Argo] 启动固定隧道(token): ${ARGO_DOMAIN}"
    nohup "$CFD_BIN" tunnel run --token "$ARGO_AUTH" --logfile "$ARGO_LOG" >/dev/null 2>&1 &
    echo $! > "$ARGO_PID_FILE"
    ARGO_HOST="$ARGO_DOMAIN"
  else
    echo "🌐 [Argo] 启动临时隧道: 127.0.0.1:${ARGO_LOCAL_PORT} -> trycloudflare.com"
    nohup "$CFD_BIN" tunnel --url "http://127.0.0.1:${ARGO_LOCAL_PORT}" \
      --no-autoupdate --protocol http2 --logfile "$ARGO_LOG" --loglevel info >/dev/null 2>&1 &
    echo $! > "$ARGO_PID_FILE"
    local i
    for ((i = 1; i <= 30; i++)); do
      ARGO_HOST="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$ARGO_LOG" 2>/dev/null | head -n1 | sed 's#https://##' || true)"
      [[ -n "$ARGO_HOST" ]] && break
      sleep 1
    done
  fi
  if [[ -n "${ARGO_HOST:-}" ]]; then
    green "✅ [Argo] 隧道已启动: ${ARGO_HOST} (pid $(cfd_pid), 日志: ${ARGO_LOG})"
  else
    red "⚠️ [Argo] 域名获取失败(不影响 vless/tuic), 可查看 ${ARGO_LOG}"
    ARGO_HOST="argodomain.pending"
  fi
}

# cloudflared 后台守护: 30s 巡检一次, 挂了自动重启隧道并刷新节点链接
argo_watch() {
  [[ -z "$CFD_BIN" ]] && return 0
  (
    while true; do
      sleep 30
      if ! cfd_alive; then
        echo "⚠️ [守护] cloudflared 不在运行, 重启 Argo 隧道..."
        argo_start
        generate_links "$(get_server_ip)"
        purple "🔗 [守护] 节点链接已刷新(临时隧道域名已换): ${LINK_TXT}"
      fi
    done
  ) &
}

# ========== renew: 停旧进程 + 清全部配置文件, 全新开始 ==========
kill_sb_instances() {  # 停掉旧脚本/sing-box/cloudflared/tee 进程(跳过本次 renew/diag 自身)
  [[ -d /proc ]] || { echo "⚠️ [renew] 本机无 /proc, 跳过停进程(如有旧实例请手动停止)"; return 0; }
  local p pid cmd
  for p in /proc/[0-9]*/cmdline; do
    pid="${p#/proc/}"
    [[ "$pid" == "$$" ]] && continue
    cmd="$(tr '\0' ' ' < "$p" 2>/dev/null || true)"
    case "$cmd" in
      *"$SB_BIN"*|*"$CFD_BIN"*|*sb_argo.sh*|*"/dev/fd/"*|*sb-run.log*)
        case "$cmd" in
          *renew*|*diag*) continue ;;
        esac
        echo "   ↪️ 停止 pid ${pid}: ${cmd}"
        kill "$pid" 2>/dev/null || true
        ;;
    esac
  done
  sleep 1
}

renew_all() {
  purple "♻️  [renew] 全新开始: 停止旧进程, 删除凭据/配置/证书/链接/日志 — 节点链接将全部更换"
  kill_sb_instances
  local f removed=0
  for f in "$ENV_FILE" "$CONF_JSON" "$CERT_PEM" "$KEY_PEM" "$LINK_TXT" \
           "$ARGO_LOG" "$ARGO_PID_FILE" "$RUN_LOG" "${RUN_LOG}.old" "$DIAG_TXT"; do
    if [[ -e "$f" ]]; then
      rm -f "$f"
      echo "   🗑️  已删除 ${f}"
      removed=1
    fi
  done
  [[ $removed -eq 0 ]] && echo "   (无旧配置文件)"
  green "✅ [renew] 清理完成, 二进制保留(sing-box/cloudflared 不重下), 即将全新部署"
}

# ========== 生成链接 ==========
generate_links() {
  local ip="$1"
  cat > "$LINK_TXT" <<EOF
vless://${UUID}@${ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${MASQ_DOMAIN}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp&headerType=none#sbargo-vless
tuic://${UUID}:${TUIC_PASS}@${ip}:${PORT}?sni=${TUIC_SNI}&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#sbargo-tuic
vmess://$(echo "{ \"v\": \"2\", \"ps\": \"sbargo-vmess\", \"add\": \"${CFIP:-${ARGO_HOST}}\", \"port\": \"${CFPORT:-443}\", \"id\": \"${UUID}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${ARGO_HOST}\", \"path\": \"/vmess-argo?ed=2048\", \"tls\": \"tls\", \"sni\": \"${ARGO_HOST}\", \"alpn\": \"\", \"fp\": \"\"}" | base64 -w0)
EOF
  purple "🔗 [链接] 节点链接已生成: ${LINK_TXT}"
  cat "$LINK_TXT"
}

# ========== 全量日志: 本次运行所有输出同步写入 sb-run.log ==========
setup_logging() {
  if [[ -s "$RUN_LOG" ]] && [[ "$(wc -c < "$RUN_LOG" | tr -d ' ')" -gt 1000000 ]]; then
    mv -f "$RUN_LOG" "${RUN_LOG}.old"
  fi
  if [[ -s "$UDP_STATS_LOG" ]] && [[ "$(wc -c < "$UDP_STATS_LOG" | tr -d ' ')" -gt 200000 ]]; then
    mv -f "$UDP_STATS_LOG" "${UDP_STATS_LOG}.old"
  fi
  exec > >(tee -a "$RUN_LOG") 2>&1
  echo "📋 [日志] 运行日志: ${RUN_LOG} (排查用, 面板可直接下载)"
}

# ========== 探测原语(启动自检与 --diag 共用) ==========
probe_tcp() {  # probe_tcp <名称> <端口>
  if (exec 3<>"/dev/tcp/127.0.0.1/$2") 2>/dev/null; then
    green "✅ TCP $1 127.0.0.1:$2 可达"
  else
    red "❌ TCP $1 127.0.0.1:$2 不可达"
  fi
}

probe_ws() {
  local code
  code="$(curl -si -m 5 -o /dev/null -w '%{http_code}' \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "http://127.0.0.1:${ARGO_LOCAL_PORT}/vmess-argo" 2>/dev/null || true)"
  if [[ "$code" == 101* ]]; then
    green "✅ vmess-ws /vmess-argo 握手 101"
  else
    red "❌ vmess-ws 握手 ${code:-无} (期望 101)"
  fi
}

probe_reality() {
  local subj
  subj="$(openssl s_client -connect "127.0.0.1:${PORT}" -servername "$MASQ_DOMAIN" </dev/null 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)"
  if [[ -n "$subj" ]]; then
    green "✅ reality 端口 TLS 回落正常: ${subj}"
  else
    red "❌ reality 端口 TLS 握手无响应"
  fi
}

# ========== 启动自检: sing-box 起来后 5s 做本地连通性探测 ==========
self_check() {
  sleep 5
  echo "🧪 [自检] 本地连通性探测..."
  probe_tcp "vless" "$PORT"
  probe_tcp "vmess-ws" "$ARGO_LOCAL_PORT"
  probe_ws
  probe_reality
  tuic_selftest
}

# tuic 本地回环自测: 用 sing-box 自身当客户端走 127.0.0.1, 区分"服务端坏了"还是"客户端/链路问题"
tuic_selftest() {
  local tconf="${WORKDIR}/.tuic-test.json" tport=18234 tcode="" tpid=""
  echo "🧪 [自检] tuic 本地回环代理测试(区分服务端/客户端侧)..."
  cat > "$tconf" <<EOF
{
  "log": {"level": "warn"},
  "inbounds": [{"type": "mixed", "tag": "test-in", "listen": "127.0.0.1", "listen_port": ${tport}}],
  "outbounds": [{"type": "tuic", "tag": "test-out", "server": "127.0.0.1", "server_port": ${PORT},
    "uuid": "${UUID}", "password": "${TUIC_PASS}", "congestion_control": "bbr", "udp_relay_mode": "native",
    "tls": {"enabled": true, "insecure": true, "alpn": ["h3"]}}]
}
EOF
  chmod 600 "$tconf" || true
  set +e
  "$SB_BIN" run -c "$tconf" >/dev/null 2>&1 &
  tpid=$!
  sleep 3
  tcode="$(curl -sx "http://127.0.0.1:${tport}" -m 12 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null || true)"
  kill "$tpid" 2>/dev/null
  set -e
  rm -f "$tconf"
  if [[ "$tcode" == "204" || "$tcode" == "200" ]]; then
    green "✅ [自检] tuic 回环代理通过(HTTP ${tcode}): 服务端 tuic 正常; 客户端不通 → 查客户端配置/UDP 链路"
  else
    red "❌ [自检] tuic 回环代理失败(HTTP ${tcode:-无响应}): 服务端 tuic 本身异常, 与客户端无关"
  fi
}

# ========== UDP 后台采样: 每 60s 记内核 UDP 计数器+负载, 供间歇故障对时 ==========
udp_monitor() {
  (
    [[ -r /proc/net/snmp ]] || exit 0
    echo "# time load= | Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors InCsumErrors IgnoredMulti"
    while true; do
      echo "$(date '+%F %T') load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null) $(grep -A1 '^Udp:' /proc/net/snmp 2>/dev/null | tail -n1)" >> "$UDP_STATS_LOG" 2>/dev/null || true
      sleep 60
    done
  ) &
}

# ========== 守护: sing-box 前台运行(日志可见, 崩溃自动重启) ==========
run_loop() {
  purple "🚀 [启动] sing-box 前台运行(vless+tuic :${PORT}), 日志直接输出, Ctrl+C 退出"
  ( self_check ) &
  while true; do
    set +e
    "$SB_BIN" run -c "$CONF_JSON"
    local rc=$?
    set -e
    echo "⚠️ [守护] sing-box 退出(码 ${rc}), 5s 后重启..."
    sleep 5
  done
}

# ========== --diag: 部署后自动采集全部诊断到 00diag.txt(单命令容器友好) ==========
collect_diag() {
  echo "🧾 [诊断] 节点已运行, 诊断采集中; 约 2 分钟后自动生成: ${DIAG_TXT}"
  sleep 45        # 等自检/客户端流量积累
  local udp1
  udp1="$(grep -A1 '^Udp:' /proc/net/snmp 2>/dev/null | tail -n1 || true)"
  {
    echo "=============================================================="
    echo " sb_argo 诊断报告  脚本版本 ${SELF_VER}  $(date '+%F %T %Z')"
    echo " 注意: 本文件含节点凭据等敏感信息, 仅自行排查或发给信任的人"
    echo "=============================================================="
    echo "--- [1] 系统 ---"
    uname -a || true
    echo
    echo "--- [1.5] 外部命令自检 ---"
    local c
    for c in curl tar openssl base64 tee awk sed grep tr cmp wc uname nohup pgrep ss netstat shuf uuidgen; do
      if command -v "$c" >/dev/null 2>&1; then echo "  ${c}: ok"; else red "  ${c}: 缺失"; fi
    done
    echo
    echo "--- [2] 相关环境变量 ---"
    env | grep -E '^(PORT|PTERODACTYL_|SERVER_|ARGO_|CFIP|CFPORT|UUID)=' | sort || echo "(无)"
    echo
    echo "--- [3] 工作目录文件 ---"
    ls -la "$WORKDIR" || true
    echo
    echo "--- [4] 凭据文件 ${ENV_FILE} ---"
    [[ -s "$ENV_FILE" ]] && cat "$ENV_FILE" || echo "(不存在)"
    echo
    echo "--- [5] 配置 ${CONF_JSON} ---"
    [[ -s "$CONF_JSON" ]] && cat "$CONF_JSON" || echo "(不存在)"
    if grep -q 'max_early_data' "$CONF_JSON" 2>/dev/null; then
      echo ">>> vmess early-data 修复: 已生效(20261011-1616+ 版本配置)"
    else
      red ">>> vmess early-data 修复: 未生效! 当前配置由旧版脚本生成, 请重新部署拉取新版"
    fi
    echo
    echo "--- [6] 节点链接 ${LINK_TXT} ---"
    [[ -s "$LINK_TXT" ]] && cat "$LINK_TXT" || echo "(不存在)"
    echo
    echo "--- [7] vmess 链接解码(核对客户端实际参数) ---"
    local b64 vm
    b64="$(sed -n 's#^vmess://##p' "$LINK_TXT" 2>/dev/null | head -n1 || true)"
    vm="$(echo "$b64" | base64 -d 2>/dev/null || true)"
    if [[ -n "$vm" ]]; then echo "$vm"; else echo "(解码失败)"; fi
    echo
    echo "--- [8] 凭据一致性核对(链接 vs env vs 配置) ---"
    local cfg
    cfg="$(cat "$CONF_JSON" 2>/dev/null || true)"
    local l_uuid l_pbk l_sid l_tpass
    l_uuid="$(sed -n 's#^vless://\([^@]*\)@.*#\1#p' "$LINK_TXT" 2>/dev/null | head -n1 || true)"
    l_pbk="$(sed -n 's#.*pbk=\([^&]*\)&.*#\1#p' "$LINK_TXT" 2>/dev/null | head -n1 || true)"
    l_sid="$(sed -n 's#.*sid=\([^&]*\)&.*#\1#p' "$LINK_TXT" 2>/dev/null | head -n1 || true)"
    l_tpass="$(sed -n 's#^tuic://[^:]*:\([^@]*\)@.*#\1#p' "$LINK_TXT" 2>/dev/null | head -n1 || true)"
    [[ "$l_uuid" == "$UUID" ]] && echo "UUID 一致: ${UUID:0:8}..." || red "UUID 不一致! 链接=${l_uuid:0:8}... env=${UUID:0:8}... (客户端用了旧链接?)"
    [[ "$l_pbk" == "$REALITY_PUB" ]] && echo "pbk 一致" || red "pbk 不一致! (客户端用了旧链接?)"
    [[ "$l_sid" == "$SHORT_ID" ]] && echo "sid 一致" || red "sid 不一致! (客户端用了旧链接?)"
    [[ "$l_tpass" == "$TUIC_PASS" ]] && echo "tuic 密码一致" || red "tuic 密码不一致! (客户端用了旧链接?)"
    [[ "$cfg" == *"${UUID}"* ]] && echo "配置内 UUID 与 env 一致" || red "配置内 UUID 与 env 不一致!"
    echo
    echo "--- [9] 进程 ---"
    if [[ -d /proc ]]; then
      local p cmd found=0
      for p in /proc/[0-9]*/cmdline; do
        cmd="$(tr '\0' ' ' < "$p" 2>/dev/null || true)"
        case "$cmd" in
          *sing-box*|*cloudflared*) echo "pid ${p#/proc/}: ${cmd}"; found=1 ;;
        esac
      done
      [[ $found -eq 0 ]] && echo "(未发现 sing-box/cloudflared 进程)"
    else
      pgrep -af 'sing-box|cloudflared' || echo "(未发现 sing-box/cloudflared 进程, 且本机无 /proc)"
    fi
    if [[ -s "$ARGO_PID_FILE" ]]; then
      local apid; apid="$(cat "$ARGO_PID_FILE" 2>/dev/null || true)"
      if [[ -n "$apid" ]] && kill -0 "$apid" 2>/dev/null; then
        echo "argo.pid=${apid} 存活=yes"
      else
        echo "argo.pid=${apid:-?} 存活=no"
      fi
    else
      echo "argo.pid: (无 pidfile)"
    fi
    echo
    echo "--- [10] 监听端口 ---"
    (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || netstat -an 2>/dev/null | head -30) | grep -vE '^Active|^Proto$' || true
    (ss -ulnp 2>/dev/null || netstat -ulnp 2>/dev/null) | grep -vE '^Active|^Proto$' || true
    echo
    echo "--- [11] 出网探测 ---"
    echo -n "公网IP: "; curl -4 -sm 8 https://api.ipify.org 2>/dev/null || echo "(失败)"; echo
    local host_now
    host_now="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$ARGO_LOG" 2>/dev/null | tail -n1 | sed 's#https://##' || true)"
    [[ -z "$host_now" && -n "${ARGO_DOMAIN:-}" ]] && host_now="$ARGO_DOMAIN"
    if [[ -n "$host_now" ]]; then
      echo -n "CF edge (${host_now}): "
      curl -sm 8 -o /dev/null -w '%{http_code}' "https://${host_now}" 2>/dev/null || echo " (失败)"
      echo
    else
      echo "Argo 域名: (未从 ${ARGO_LOG} 解析到)"
    fi
    echo
    echo "--- [11.5] UDP 专检(tuic 间歇故障用) ---"
    echo "UDP 缓冲: rmem_max=$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo '?') rmem_default=$(cat /proc/sys/net/core/rmem_default 2>/dev/null || echo '?')"
    echo -n "UDP 监听: "
    (ss -ulnp 2>/dev/null || netstat -ulnp 2>/dev/null) | grep -viE '^State|^Proto|command not found' | grep -iE "udp|:${SB_PORT:-}" | head -3 || echo "(未查到)"
    echo "UDP 计数(当前): $(grep -A1 '^Udp:' /proc/net/snmp 2>/dev/null | tail -n1)"
    echo "UDP 采样(首): $(sed -n '2p' "$UDP_STATS_LOG" 2>/dev/null)"
    echo "UDP 采样(末): $(tail -n1 "$UDP_STATS_LOG" 2>/dev/null)"
    echo "tuic 错误统计(本次运行): $(grep -c 'tuic.*authentication timeout' "$RUN_LOG" 2>/dev/null || true) 次 authentication timeout"
    echo
    echo "--- [12] Argo 日志 ${ARGO_LOG} (末 40 行) ---"
    tail -n 40 "$ARGO_LOG" 2>/dev/null || echo "(不存在)"
    echo
    echo "--- [13] 运行日志 ${RUN_LOG} (末 80 行) ---"
    tail -n 80 "$RUN_LOG" 2>/dev/null || echo "(不存在)"
    echo
    echo "--- [14] 实时探测(本机回环, 节点运行中) ---"
    probe_tcp "vless" "$PORT"
    probe_tcp "vmess-ws" "$ARGO_LOCAL_PORT"
    probe_ws
    probe_reality
    tuic_selftest
    echo
    echo "--- [15] UDP 间隔采样(60s, InErrors/RcvbufErrors 增量>0 = 内核丢包) ---"
    echo "快照1: ${udp1:-?}"
    sleep 60
    echo "快照2: $(grep -A1 '^Udp:' /proc/net/snmp 2>/dev/null | tail -n1 || true)"
    echo
    echo "=============================================================="
    echo " 报告结束: ${DIAG_TXT}"
    echo "=============================================================="
  } > "$DIAG_TXT" 2>&1
  echo "✅ [诊断] 报告已生成: ${DIAG_TXT} (含敏感信息, 注意保管)"
}

# ========== 主流程 ==========
main() {
  setup_logging
  echo "🧩 [版本] sb_argo ${SELF_VER}"
  check_deps
  echo "📁 工作目录: ${WORKDIR}"
  echo "🖥️  系统: $(uname -sm)"
  detect_port
  if [[ -n "$ENV_PORT" ]]; then
    echo "✅ [端口] 环境指定: ${ENV_PORT} (来源 ${PORT_SRC})"
  else
    echo "🎲 [端口] 未指定, 复用已保存端口或随机分配"
  fi
  ensure_self
  download_bins
  load_credentials
  echo "✅ [端口] 生效: ${PORT} (vless=TCP, tuic=UDP, 同端口)"
  generate_cert
  generate_config
  argo_start
  argo_watch
  udp_monitor
  local ip; ip="$(get_server_ip)"
  echo "🌐 服务器 IP: ${ip}"
  generate_links "$ip"
  green "💾 [自举] 脚本/依赖/凭据均已落地 ${WORKDIR}; NAT 机免 crontab, 重启后执行: bash ${SELF_FILE}"
  if [[ "${DIAG_MODE:-0}" == "1" ]]; then
    ( collect_diag ) &
  fi
  run_loop
}

# ========== 入口: --diag 部署+诊断 / renew 全新部署 / 其余正常部署 ==========
if [[ "${1:-}" == "--diag" || "${1:-}" == "diag" ]]; then
  DIAG_MODE=1
fi
if [[ "${1:-}" == "renew" || "${1:-}" == "--renew" ]]; then
  renew_all
fi
main
