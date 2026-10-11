# sb_argo 自举改造与 Argo 固定域名全链路调试

- 日期: 20261011 ~ 20261012
- 交付: sb_argo.sh 从单次部署脚本升级为"自举 + 守护 + 诊断 + 固定域名"一体化方案
- 最终版本: 20261012-0004 (commit a079593)

## 一、需求与讨论历程

1. **自举**: NAT 容器(翼龙类, 单命令入口, 无 crontab)需脚本自身/依赖/凭据全部落地本地, 重启后 `bash sb_argo.sh` 直接恢复且节点链接不变。参考 tuic.sh(凭据持久化)与 easy-docker-proxy/run.sh(管道自举落地)。
2. **三协议排障**: 用户 v2rayN 实测 vless/tuic/vmess 依次报错, 需逐一定位。
3. **诊断自动化**: 容器一个时刻只能跑一个命令, 所有诊断必须集成进脚本、一次运行产出报告。
4. **Argo 固定域名**: 临时隧道域名每次重启都换, 需固定域名; 用户使用第三方共享 token(argotk 服务商), 面板无法注入环境变量。
5. **固定域名变慢**: 要求固定+临时双链接并存。

## 二、关键问题定位(过程结论)

| 现象 | 根因 |
|---|---|
| vmess `bad request` | 服务端 vmess-ws 缺 `max_early_data`/`early_data_header_name`, `?ed=2048` 客户端请求头丢失 |
| vless `REALITY invalid connection` / tuic `authentication timeout`(初期) | 客户端持旧凭据(部署换代后未重新导入) |
| cloudflared 每 30s 被误重启、域名连环换 | 容器无 pgrep, 守护巡检误判; 改 pidfile+kill -0 |
| 自更新/依赖下载在墙内失败 | GitHub 直连被墙; 加 ghproxy.net/gh-proxy.com 镜像链 |
| tuic "间歇性中断" | 从本机用 sing-box 1.10.7/1.13.18 直连实测全通(含 90s 空闲), 服务端回环 204; 定性为**直连链路对 UDP/QUIC 的时段性 QoS**(晚高峰), 与配置无关; 建议走中转或用 TCP 协议 |
| 服务端 REALITY invalid(127.0.0.1) | 自检 openssl 探测的预期内错误, 非故障 |
| 固定隧道反复重启 | `tunnel run --token X --no-autoupdate ...` 全局参数跟在 run 后致 token 丢失秒退; 正确顺序为 `tunnel --no-autoupdate ... run --token X`(对齐 eooce 写法) |
| token 报 not valid | cloudflared 只认**裸 payload**(eyJhIjoi...), 加 JWT 头反而错; conf 若 CRLF 上传, 值尾 \r 也会致无效 |
| 固定域名 502 | 云端托管隧道回源端口由服务商远程配置决定(lunes→8001, argotk→44020), 脚本改为自动读取并适配 |

## 三、代码变更(sb_argo.sh, 按版本)

- 1602 自举: 管道执行自动落地脚本+依赖, 凭据持久化 sb_argo.env(600), cloudflared 纳入守护
- 1616 vmess-ws 补 early-data; 全量运行日志 sb-run.log; --diag 自检报告
- 1705 多源下载(直连→ghproxy 镜像); SELF_VER 版本落日志
- 1724 守护改 pidfile+kill-0(免 pgrep); 1727 启动外部命令依赖自检; 1733 renew 参数(清配置全新开始)
- 1758 tuic 本地回环自测(sing-box 自身当客户端)+UDP 内核计数后台采样
- 1810 --diag 一条龙(部署+运行+2 分钟自动生成报告); 1815 链接文件改名 00links.txt
- 2257 sb_argo.conf 配置文件(面板无法传环境变量时 KEY=VALUE 落文件, 环境变量优先)
- 2334 token 直传裸 payload; conf 值剥 \r; 2353 token 模式参数顺序修复+云端回源端口自动适配
- **0004(当前) 固定+临时双隧道并行**: 各自 pidfile/日志/守护巡检, 00links 同时输出 sbargo-vmess-argo 与 sbargo-vmess-temp 两条 vmess

配套: README 增固定域名配置指南与双隧道说明。

## 四、一条命令生成 argo 固定域名配置文件(demo)

```bash
printf 'ARGO_DOMAIN=argo.example.com\nARGO_AUTH=eyJ你的token\n' > /home/container/sb_argo.conf
```

掩码校验(不泄露 token):

```bash
sed 's/\(=.\{8\}\).*/\1.../' /home/container/sb_argo.conf
```

## 五、验证方式

- 本地 mock 环境(curl/tar/sing-box/cloudflared 全桩)覆盖: 首次部署/重启复用/断网回退/崩溃守护/renew/CRLF conf/json 转换/双隧道
- 真实工具实测: 本机 sing-box(1.10.7 与 v2rayN 自带 1.13.18)直连测 tuic; 真实 cloudflared 验证 token 格式、参数顺序、云端回源配置、argotk 域名端到端穿透(本地 44020 取回内容)

## 六、遗留事项

- 固定域名速度可能逊于临时隧道, 已双链接并存供选择; 长期建议自有域名自建隧道
- tuic 直连受运营商 UDP QoS 影响属链路问题, 客户端走中转即可
- v2rayN 导入 tuic 链接后 uuid/password 存于 Username/Password 列(Id/Security 为空是正常表结构)

---
by ZCode / GLM-5.3
