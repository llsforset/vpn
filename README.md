# VLESS + Xray + Reality 一键搭建

一个仓库搞定个人代理服务端部署:自动识别系统类型(Debian / Ubuntu / CentOS / Rocky / AlmaLinux),一键完成 Xray 安装、Reality 密钥生成、伪装目标站验证、BBR 加速、防火墙放行和服务启动,最后把客户端连接信息(含 `vless://` 一键导入链接)打印并保存到服务器。

> 方案:**VLESS + TCP + Reality(xtls-rprx-vision)**——无需域名、无需证书,TLS 握手借用真实大站证书回显,中间人探测只能看到一个"正在访问正常网站"的普通连接,是目前抗识别能力最强的方案之一。

## 目录结构

```
vpn/
├── install.sh             # 一键安装脚本(核心)
├── uninstall.sh           # 卸载脚本
├── client/
│   └── clash-meta.yaml    # Clash Meta 客户端配置示例
└── README.md
```

## 服务器要求

| 项目 | 要求 |
|---|---|
| 系统 | Debian 10+ / Ubuntu 18.04+ / CentOS 7+ / Rocky / AlmaLinux |
| 配置 | 1核1G 起步(个人自用绰绰有余) |
| 权限 | root |
| 网络 | 服务器需能访问 GitHub(Xray 安装脚本) |

## 服务端:一键安装

```bash
git clone <本仓库地址> && cd vpn
bash install.sh        # 默认端口 443
# 或者指定端口:
bash install.sh 8443
```

脚本会自动完成:

1. 检测系统类型(apt 系 / yum 系),安装 curl、openssl 等依赖
2. 官方脚本安装 Xray 最新版
3. 内核 ≥ 4.9 时启用 BBR 加速(旧内核自动跳过并提示)
4. 从候选列表验证并选择支持 TLS1.3 的 Reality 伪装目标站(SNI)
5. 自动生成 UUID、x25519 密钥对、shortId
6. 写入服务端配置 `/usr/local/etc/xray/config.json`
7. 放行防火墙(ufw / firewalld 自动识别)
8. 启动服务并输出**完整连接参数 + `vless://` 导入链接**

安装成功后,所有连接信息保存在服务器 **`/root/vpn-info.txt`**(权限 600),随时查看:

```bash
cat /root/vpn-info.txt
```

> ⚠️ 记得在**云厂商控制台的安全组**里放行对应端口(脚本只能改系统防火墙,动不了云平台安全组)。

## 服务端日常管理

```bash
systemctl restart xray      # 重启
systemctl status xray       # 状态
journalctl -u xray -f       # 实时日志
ss -tlnp | grep 443         # 确认端口监听
```

修改端口 / 换用户:改 `/usr/local/etc/xray/config.json` 后 `systemctl restart xray`;彻底卸载:`bash uninstall.sh`。

## 客户端接入

### 方式一:vless:// 链接一键导入(推荐)

安装完成后脚本会打印一条 `vless://...` 链接(也在 `/root/vpn-info.txt` 里),以下客户端直接"从剪贴板导入"即可:

| 平台 | 客户端 |
|---|---|
| Windows | v2rayN |
| macOS | V2rayU / Nekoray |
| Android | NekoBox / v2rayNG |
| iOS | Shadowrocket / Stash |

### 方式二:Clash Meta (mihomo) 手动配置

> ⚠️ **原版 Clash 内核不支持 VLESS/Reality**,必须使用 Meta 内核客户端:
> **Clash Verge Rev**(Windows/macOS/Linux)、**FlClash / ClashMetaForAndroid**(Android)。

1. 复制本仓库 `client/clash-meta.yaml` 作为配置模板
2. 把 4 个占位符替换为服务器上的实际值(`cat /root/vpn-info.txt`):
   - `<服务器IP>`、`<UUID>`、`<SNI>`、`<PUBLIC_KEY>`、`<SHORT_ID>`
3. 导入客户端;核心参数对应关系:

| Clash 字段 | 值 |
|---|---|
| `type` | vless |
| `flow` | xtls-rprx-vision |
| `network` | tcp |
| `tls` | true |
| `servername` | 安装时的 SNI(如 www.samsung.com) |
| `client-fingerprint` | chrome |
| `reality-opts.public-key` | x25519 公钥 |
| `reality-opts.short-id` | shortId |

3. 规则建议用 `client/clash-meta.yaml` 里的 GEOIP 分流(国内直连、国外走代理),省服务器流量。

## 常见问题

| 问题 | 处理 |
|---|---|
| 连不上,客户端握手超时 | ① 云安全组没放行端口;② `journalctl -u xray` 看服务是否正常;③ IP 被墙(换 IP 或端口) |
| Reality 握手失败 | SNI 目标站失效或不再支持 TLS1.3,重新跑 `pick_sni` 逻辑换一个(改 config 后重启) |
| 速度慢 | 确认 BBR 生效(`sysctl net.ipv4.tcp_congestion_control`);晚高峰测试,劣化明显则考虑换线路(回程 CN2 GIA / CMIN2 / CUG) |
| 想多加用户 | config.json 的 `clients` 数组里加一行新 UUID 即可,重启生效 |

## 安全与合规

- **仅限个人自用**。在国内倒卖/共享代理服务属违法行为;请勿用于任何违法用途
- SSH 建议改密钥登录并安装 fail2ban;`/root/vpn-info.txt` 含敏感信息,勿外传
- 定期 `apt update && apt upgrade` 更新系统与 Xray(`bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) @ install` 可原地升级,配置不受影响)

## 参考

- [Xray 官方文档](https://xtls.github.io/)
- [XTLS-REALITY 协议说明](https://github.com/XTLS/Xray-core/discussions/1689)
- [mihomo (Clash.Meta) 内核](https://github.com/MetaCubeX/mihomo)

## 踩坑记录（实战排障结论）

1. **云厂商安全组**：脚本只能改系统防火墙，**厂商控制台的防火墙/安全组必须手动放行**——有的厂商默认只放行 SSH 端口，其余全部入站阻断（ping 通、SSH 通、443 不通就是这么来的）。
2. **Xray 与客户端内核的版本兼容**：Xray-core v26.x 起改了 Reality 协议，mihomo ≤1.19.x、旧版客户端会握手被拒（服务端日志表现为 `REALITY: processed invalid connection: authentication failed or validation criteria not met`，TCP 通但认证失败）。**服务端和客户端内核要选同时代版本**：新 xray 配新 mihomo/sing-box，或老 xray（如 v25.6.7）配老客户端。
3. **Clash Verge Rev 本地 profile**：必须自带完整 `dns:` 块（fake-ip 模式），且不要写 `mixed-port`/`allow-lan` 等被 Verge 托管的字段——否则 TUN 模式下 DNS 黑洞直接全断网。
