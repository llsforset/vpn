#!/usr/bin/env bash
#
# install.sh — VLESS + Xray + Reality 一键安装脚本
# 支持: Debian 10+ / Ubuntu 18.04+ / CentOS 7+ / Rocky / AlmaLinux / RHEL
# 用法: bash install.sh [端口, 默认 443]
#
set -euo pipefail

PORT="${1:-443}"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
INFO_FILE="/root/vpn-info.txt"
XRAY_INSTALLER="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

# Reality dest/SNI 候选(需支持 TLS1.3 + h2, 建议选非 CDN 大站)
SNI_CANDIDATES=("www.samsung.com" "www.lovelive-anime.jp" "www.nvidia.com" "www.speedtest.net" "www.apple.com")

# ---------- 输出工具 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# ---------- 前置检查 ----------
[[ $EUID -eq 0 ]] || fail "请用 root 运行: sudo bash $0"

# ---------- 系统检测 ----------
detect_os() {
    if [[ ! -r /etc/os-release ]]; then
        fail "无法读取 /etc/os-release, 不支持的系统"
    fi
    . /etc/os-release
    case "${ID,,}" in
        debian|ubuntu)
            PKG="apt"
            info "检测到系统: $PRETTY_NAME (apt 系)"
            ;;
        centos|rhel|rocky|almalinux|anolis|fedora|amzn)
            PKG="yum"
            command -v dnf >/dev/null 2>&1 && PKG="dnf"
            info "检测到系统: $PRETTY_NAME (${PKG} 系)"
            ;;
        *)
            fail "暂不支持该系统: $PRETTY_NAME (仅支持 Debian/Ubuntu/CentOS/Rocky/AlmaLinux)"
            ;;
    esac
}

install_deps() {
    info "安装基础依赖 (curl / openssl)..."
    if [[ "$PKG" == "apt" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y curl openssl lsof
    else
        ${PKG} install -y curl openssl lsof
    fi
    ok "依赖就绪"
}

install_xray() {
    info "安装 Xray 核心 (官方脚本)..."
    bash -c "$(curl -Ls "$XRAY_INSTALLER")" @ install
    command -v xray >/dev/null 2>&1 || fail "Xray 安装失败"
    ok "Xray 版本: $(xray version | head -1)"
}

enable_bbr() {
    local kernel_major
    kernel_major=$(uname -r | cut -d. -f1)
    local kernel_minor
    kernel_minor=$(uname -r | cut -d. -f2)
    if (( kernel_major > 4 )) || (( kernel_major == 4 && kernel_minor >= 9 )); then
        cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
        sysctl --system >/dev/null 2>&1
        if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
            ok "BBR 已启用"
        else
            warn "BBR 启用未生效(内核可能未编译 bbr 模块), 不影响使用"
        fi
    else
        warn "内核 $(uname -r) < 4.9, 无法启用 BBR (CentOS 7 请自行升级内核), 继续安装"
    fi
}

# 从候选中选一个支持 TLS1.3 的 Reality dest/SNI
pick_sni() {
    info "选择 Reality 伪装目标站 (SNI)..."
    for host in "${SNI_CANDIDATES[@]}"; do
        if openssl s_client -connect "${host}:443" -servername "$host" -tls1_3 </dev/null 2>/dev/null \
            | grep -q "TLSv1.3"; then
            SNI="$host"
            ok "SNI 目标: $SNI (TLS1.3 验证通过)"
            return
        fi
        warn "$host 不支持 TLS1.3, 跳过"
    done
    SNI="www.samsung.com"
    warn "候选全部验证失败, 使用默认: $SNI"
}

gen_secrets() {
    info "生成密钥材料..."
    UUID=$(cat /proc/sys/kernel/random/uuid)
    local keyout
    keyout=$(xray x25519)
    # 兼容新旧 Xray 输出格式: 旧版 "Private key:/Public key:", 新版(v25+) "PrivateKey:/Password (PublicKey):"
    PRIVATE_KEY=$(echo "$keyout" | awk '/Private key:|PrivateKey:/ {print $NF}' | head -1)
    PUBLIC_KEY=$(echo "$keyout" | awk '/Public key:|Password \(PublicKey\):/ {print $NF}' | head -1)
    SHORT_ID=$(openssl rand -hex 8)
    [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || fail "密钥生成失败"
    ok "UUID / x25519 密钥对 / shortId 已生成"
}

write_config() {
    info "写入配置: $XRAY_CONFIG"
    mkdir -p "$(dirname "$XRAY_CONFIG")"
    cat > "$XRAY_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${SNI}:443",
        "xver": 0,
        "serverNames": ["${SNI}"],
        "privateKey": "${PRIVATE_KEY}",
        "shortIds": ["${SHORT_ID}"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    ok "配置写入完成"
}

config_firewall() {
    info "配置防火墙放行 ${PORT}/tcp ..."
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${PORT}/tcp" && ok "ufw 已放行"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl -q is-active firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
        firewall-cmd --reload >/dev/null
        ok "firewalld 已放行"
    else
        warn "未检测到启用的防火墙 (ufw/firewalld), 跳过"
    fi
    warn "云厂商控制台的安全组需自行放行 ${PORT}/tcp"
}

start_service() {
    info "启动 xray 服务..."
    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray
    sleep 1
    systemctl is-active --quiet xray || {
        journalctl -u xray --no-pager -n 20
        fail "xray 启动失败, 请查看上方日志"
    }
    ss -tlnp 2>/dev/null | grep -q ":${PORT} " && ok "端口 ${PORT} 正在监听" || warn "未检测到 ${PORT} 监听(可能延迟), 请稍后手动检查"
}

get_public_ip() {
    curl -4 -s --max-time 8 https://api.ip.sb/ip 2>/dev/null \
        || curl -4 -s --max-time 8 https://ifconfig.me 2>/dev/null \
        || ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1 \
        || echo "YOUR_SERVER_IP"
}

write_info() {
    VLESS_URI="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality-${SNI}"

    cat > "$INFO_FILE" <<EOF
==============================================
 VLESS + Reality 安装完成  $(date '+%Y-%m-%d %H:%M:%S')
==============================================
 地址(address)    : ${PUBLIC_IP}
 端口(port)       : ${PORT}
 用户ID(uuid)     : ${UUID}
 流控(flow)       : xtls-rprx-vision
 传输(network)    : tcp
 安全(security)   : reality
 SNI(serverName)  : ${SNI}
 指纹(fingerprint): chrome
 公钥(publicKey)  : ${PUBLIC_KEY}
 shortId          : ${SHORT_ID}
----------------------------------------------
 一键导入 URI:
 ${VLESS_URI}
--------------------------------==============
 配置文件 : ${XRAY_CONFIG}
 常用命令 : systemctl restart xray | journalctl -u xray -f
==============================================
EOF
    chmod 600 "$INFO_FILE"

    echo
    echo -e "${GREEN}=============================================="
    echo -e "  安装完成! 连接信息已保存到 ${INFO_FILE}"
    echo -e "==============================================${NC}"
    cat "$INFO_FILE"
    echo
    echo -e "${CYAN}>> 客户端可直接复制上面的 vless:// URI 导入 (v2rayN / Shadowrocket / NekoBox)${NC}"
    echo -e "${CYAN}>> Clash Meta (mihomo) 用户参考仓库内 client/clash-meta.yaml${NC}"
}

# ---------- 主流程 ----------
main() {
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}  VLESS + Xray + Reality 一键安装${NC}"
    echo -e "${CYAN}======================================${NC}"
    detect_os
    install_deps
    install_xray
    enable_bbr
    pick_sni
    gen_secrets
    write_config
    config_firewall
    start_service
    PUBLIC_IP=$(get_public_ip)
    write_info
}

main
