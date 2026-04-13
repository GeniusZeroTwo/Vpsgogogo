#!/usr/bin/env bash
# ====================================================
# 脚本功能：内核极致优化 (BBR + FQ) + 单核硬件降载 + Hysteria2 守候
# 说明：更安全、更幂等的实现；适用 Debian 11+, Ubuntu 20.04+
# 运行：以 root 身份执行
# ====================================================

set -euo pipefail
IFS=$'\n\t'

GREEN='\033[0;32m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

echo -e "${BLUE}开始执行内核极致优化脚本...${PLAIN}"

# 检查是否 root
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 身份运行此脚本。" >&2
  exit 1
fi

# 全局变量
SYSCTL_DROPIN="/etc/sysctl.d/99-vps-optimize.conf"
SYSCTL_BACKUP_DIR="/root/sysctl-backups"
HYSTERIA_BIN="/usr/local/bin/hysteria"
SYSTEMD_UNIT="/etc/systemd/system/hysteria-server.service"

mkdir -p "$SYSCTL_BACKUP_DIR"

# 1. 清理旧配置（仅移除本脚本产生的块，保留用户其他自定义）
cleanup_configs() {
  echo "清理旧的冗余网络参数..."
  # 备份现有 drop-in 与 /etc/sysctl.conf
  if [ -f "$SYSCTL_DROPIN" ]; then
    cp -a "$SYSCTL_DROPIN" "${SYSCTL_BACKUP_DIR}/99-vps-optimize.conf.$(date +%s)"
    rm -f "$SYSCTL_DROPIN"
  fi

  if [ -f /etc/sysctl.conf ]; then
    cp -a /etc/sysctl.conf "${SYSCTL_BACKUP_DIR}/sysctl.conf.bak.$(date +%s)"
    # 仅删除由本脚本标记的块（若存在）
    sed -i '/# ===== VPS Optimize =====/,/# ===== End VPS Optimize =====/d' /etc/sysctl.conf || true
  fi

  # 移除旧的 systemd 单元（仅当为我们创建的文件）
  if [ -f "$SYSTEMD_UNIT" ]; then
    cp -a "$SYSTEMD_UNIT" "${SYSCTL_BACKUP_DIR}/hysteria-server.service.bak.$(date +%s)"
    rm -f "$SYSTEMD_UNIT"
    systemctl daemon-reload || true
  fi
}

# 2. 写入新内核参数到 sysctl.d（幂等）
write_sysctl() {
  echo "写入内核参数到 $SYSCTL_DROPIN ..."
  cat > "$SYSCTL_DROPIN" <<'EOF'
# ===== VPS Optimize =====
# 网络调度与拥塞控制 (BBR + FQ)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# UDP 性能优化 (专为 Hysteria2/QUIC 调优)
net.ipv4.udp_mem = 32768 131072 524288
net.core.optmem_max = 1048576

# 缓冲区优化: 支持 1000M+ 带宽与高延迟链路 (128MB Max)
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.ipv4.tcp_rmem = 4096 16777216 134217728
net.ipv4.tcp_wmem = 4096 16777216 134217728
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# 高并发请求连接优化
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1

# BBR 专用 Pacing 低水位限制 (减少单核 CPU 波动)
net.ipv4.tcp_notsent_lowat = 16384

# TCP 高级属性
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_ecn = 1
# ===== End VPS Optimize =====
EOF

  # 立即生效
  sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_DROPIN" >/dev/null 2>&1 || true
}

# 2.1 确保 BBR 模块加载
ensure_bbr() {
  echo "检查并加载 BBR 模块..."
  if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    if ! lsmod | grep -q tcp_bbr; then
      modprobe tcp_bbr || true
    fi
    # 持久化模块加载（如果支持）
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf || true
  fi
}

# 3. 硬件层面降载 (针对单核 VPS)
optimize_hardware() {
  echo "执行硬件级优化 (中断合并 + 卸载开启)..."

  # 停用 irqbalance 仅当存在且正在运行
  if systemctl list-unit-files | grep -q '^irqbalance'; then
    systemctl stop irqbalance 2>/dev/null || true
    systemctl disable irqbalance 2>/dev/null || true
  fi

  # 安装 ethtool 如果缺失
  if ! command -v ethtool >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y ethtool >/dev/null 2>&1 || true
  fi

  # 获取主要网卡（排除 lo、docker、veth、tun、tap、br）
  mapfile -t interfaces < <(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|en|ens|enp|eno)' || true)

  for iface in "${interfaces[@]:-}"; do
    [ -z "$iface" ] && continue
    # 跳过虚拟或 down 的接口
    if ip link show "$iface" 2>/dev/null | grep -q "LOOPBACK"; then
      continue
    fi

    echo "优化网卡: $iface"

    # 1. 尝试读取并设置 ring buffer 到最大值（若支持）
    if command -v ethtool >/dev/null 2>&1; then
      if ethtool -g "$iface" >/dev/null 2>&1; then
        # 解析 RX 最大值
        max_rx=$(ethtool -g "$iface" 2>/dev/null | awk '/RX:/ {print $2; exit}' || echo "")
        if [[ "$max_rx" =~ ^[0-9]+$ ]] && [ "$max_rx" -gt 0 ]; then
          ethtool -G "$iface" rx "$max_rx" >/dev/null 2>&1 || true
        fi
      fi

      # 2. 开启自适应中断合并或设置 rx-usecs
      ethtool -C "$iface" adaptive-rx on >/dev/null 2>&1 || ethtool -C "$iface" rx-usecs 50 >/dev/null 2>&1 || true

      # 3. 开启硬件卸载（容错）
      ethtool -K "$iface" tso on gso on gro on >/dev/null 2>&1 || true
    fi

    # 4. 使用 tc 设置 FQ（replace 保证幂等）
    if command -v tc >/dev/null 2>&1; then
      tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 || true
    fi
  done
}

# 4. Hysteria2 守候服务配置（非交互模式下默认不启用 warp 等待）
configure_hysteria() {
  if [ ! -x "$HYSTERIA_BIN" ]; then
    echo -e "${BLUE}未检测到 Hysteria2 可执行文件，跳过服务配置。${PLAIN}"
    return
  fi

  # 交互式询问仅在有 tty 时进行；否则默认不启用 warp 等待
  is_warp="N"
  if [ -t 0 ]; then
    read -r -p "是否为落地机开启 Warp 依赖守护模式? [y/N]: " is_warp
  fi

  wait_cmd=""
  if [[ "$is_warp" =~ ^[Yy]$ ]]; then
    wait_cmd="ExecStartPre=/bin/sh -c 'until ip addr show warp >/dev/null 2>&1; do sleep 2; done'"
  fi

  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Hysteria Server Service (Optimized)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/lib/hysteria
$wait_cmd
ExecStart=$HYSTERIA_BIN server --config /etc/hysteria/config.yaml
Restart=always
RestartSec=3s
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
LimitNOFILE=200000

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload || true
  systemctl enable --now hysteria-server.service >/dev/null 2>&1 || true
  echo "Hysteria2 系统服务已更新并尝试启动。"
}

# 5. 输出当前关键状态以便验证
print_status() {
  echo -e "${GREEN}====================================================${PLAIN}"
  echo "优化完成！当前关键状态："
  echo -n "TCP 拥塞控制: " && sysctl net.ipv4.tcp_congestion_control || true
  echo -n "默认调度器: " && sysctl net.core.default_qdisc || true
  echo -n "rmem_max: " && sysctl net.core.rmem_max || true
  echo -n "wmem_max: " && sysctl net.core.wmem_max || true
  echo -e "----------------------------------------------------"
  echo -e "提示：FQ + BBR 已尝试生效，单核硬件降载已完成。"
  echo -e "如果修改了 Hysteria2 配置，请重启服务：systemctl restart hysteria-server"
  echo -e "====================================================${PLAIN}"
}

# 执行流程
cleanup_configs
write_sysctl
ensure_bbr
optimize_hardware
configure_hysteria
print_status
