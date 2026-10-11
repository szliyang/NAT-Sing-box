# NAT-Sing-box 端口自动获取 + sb_argo 单端口脚本

## 需求

1. 参考 `tuic-hy2-node.js-python/tuic.sh` 的端口自动获取逻辑，让 NAT-Sing-box 的 sh 脚本在 NAT（翼龙/Pterodactyl）服务器上自动获取分配端口，无需手动填写。
2. 针对"单端口 NAT 机"新建一个脚本：1 个 TCP（vless-reality）+ 1 个 UDP（tuic）共用同一端口，vmess-ws 交给 Argo 隧道（不占本地端口）。

## 讨论

- **为什么选 vless(TCP) + tuic(UDP) 同端口**：TCP 与 UDP 同端口号是两个独立套接字，互不冲突；而 hy2 与 tuic 都是 QUIC/UDP，无法共用同一 UDP 端口；vless-reality 与 vmess 都是 TCP 也无法共用。
- **为什么 vmess-ws 走 Argo**：Argo 隧道（cloudflared）只承载 HTTP/WebSocket 层流量，vmess-ws 基于 HTTP WebSocket 升级可以装入；QUIC（hy2/tuic）是纯 UDP 协议无法装进 HTTP，vless-reality 是裸 TCP 同样不适合。故单端口布局下放弃 hy2，vmess-ws 走 Argo 完全不占本地端口。
- **端口优先级**：`PORT` > `PTERODACTYL_SERVER_PORT` > `SERVER_PORT` > 随机。翼龙面板会向容器注入这些环境变量。
- **IP 获取**：NAT 容器内 `curl ip.sb` 等外网探测拿到的是宿主出口 IP，需优先取面板注入的 `PTERODACTYL_SERVER_IP` / `SERVER_IP`。
- **临时隧道局限**：trycloudflare 临时隧道域名每次重启会变，重启后 vmess 节点需用新链接（vless/tuic 不受影响）；固定域名需配置 `ARGO_AUTH`+`ARGO_DOMAIN`。

## 代码变更

### sing-box.sh（修改）
- 新增 `detect_port()`：端口优先级 PORT > PTERODACTYL_SERVER_PORT > SERVER_PORT > 随机，替换原来只认 `PORT` 否则随机的逻辑（随机端口在 NAT 机上没被映射，节点必然不通）。
- `get_realip()` 开头新增翼龙 `PTERODACTYL_SERVER_IP` / `SERVER_IP` 优先判断。
- 头部追加变更记录注释（20261011-xxxx）。

### sb_argo.sh（新建）
- 单端口三协议布局：vless-reality（TCP）+ tuic（UDP）同 `detect_port()` 端口，vmess-ws 监听 127.0.0.1:8001（`ARGO_PORT` 可调）交给 Argo。
- 免 root、容器友好：不碰 /etc、不用 systemd，sing-box 前台守护循环 + cloudflared nohup 后台，风格对齐 tuic.sh。
- sing-box v1.10.7 按架构（amd64/arm64/armv7）自动下载；reality 密钥对用 `sing-box generate reality-keypair` 现生成；tuic 自签证书（客户端 allow_insecure=1）；三协议同 UUID，tuic 密码随机 hex。
- Argo 双模式：`ARGO_AUTH`+`ARGO_DOMAIN` 走 token 固定域名隧道；否则开 trycloudflare 临时隧道，从日志轮询 30s 提取域名写入链接。
- 三个节点链接统一写入 `sb_argo_link.txt`。

### README.md（修改）
- 新增"单端口 NAT 机专用脚本(sb_argo.sh)"使用说明小节。

## 验证

- `sing-box.sh`、`sb_argo.sh` 均通过 `bash -n` 语法检查。
- `detect_port()` 四级优先级（PORT=12345 > PT=25000 > SP=26000 > 随机）实测通过。
- sb_argo.sh 未在真实 NAT 容器上实测，建议先在测试机验证三个节点连通性。

## 未改动说明

- sb4.sh / sb_00.sh / sb_serv00.sh 为 serv00/ct8 面板专用，通过 `devil port` 已自动管理端口，无需改动。

---
20261011-1056
by ZCode (GLM-5.3)
