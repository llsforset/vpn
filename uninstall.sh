#!/usr/bin/env bash
#
# uninstall.sh — 卸载 Xray + 清理配置
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }

[[ $EUID -eq 0 ]] || { echo "请用 root 运行: sudo bash $0"; exit 1; }

info "停止并禁用 xray 服务..."
systemctl disable --now xray 2>/dev/null || true

info "卸载 Xray (官方脚本)..."
bash -c "$(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge 2>/dev/null \
    || echo -e "${RED}官方卸载失败, 手动清理...${NC}"

info "清理残留..."
rm -f /etc/sysctl.d/99-bbr.conf /root/vpn-info.txt
sysctl --system >/dev/null 2>&1 || true

ok "卸载完成 (系统 BBR 相关内核参数已还原默认)"
