#!/bin/bash

# ====================================================
# 脚本功能：内核极致优化 (BBR + FQ) + 单核硬件降载 + Hysteria2 增强守候
# 更新说明：切换为 FQ 调度，增强了 UDP 性能调优
# 适用系统：Debian 11+, Ubuntu 20.04+ (Root 权限)
# ====================================================

set -e

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

echo -e "${BLUE}开始执行内核极致优化脚本...${PLAIN}"

# 1. 清理旧配置
cleanup_configs() {
    echo "清理旧的冗余网络参数..."
    local sysctl_file="/etc/sysctl.conf"
    cp -a "$sysctl_file" "${sysctl_file}.bak.$(date +%s)"

    # 定义需要清理的键值对前缀
    local params=(
        "net.ipv4.tcp_congestion_control" "net.core.default_qdisc"
        "net.ipv4.tcp_rmem" "net.ipv4.tcp_wmem" "net.core.rmem_max" "net.core.wmem_max"
        "net.ipv4.udp_mem" "net.core.optmem_max" "net.ipv4.tcp_fastopen"
        "net.core.somaxconn" "net.core.netdev_max_backlog" "net.ipv4.tcp_max_syn_backlog"
        "net.ipv4.tcp_slow_start_after_idle" "net.ipv4.tcp_mtu_probing"
    )

    for param in "${params[@]}"; do
        sed -i "/^\s*${param}\s*=/d" "$sysctl_file"
    done
    
    # 清理标记块
    sed -i '/# ===== VPS Optimize =====/,/# ===== End VPS Optimize =====/d' "$sysctl_file"
    rm -f /etc/sysctl.d/99-vps-optimize.conf /etc/sysctl.d/bbr.conf
}

# 2. 写入新内核参数 (BBR + FQ)
write_sysctl() {
    echo "写入内核参数: BBR + FQ (128MB 缓冲区)..."
    cat >> /etc/sysctl.conf <<EOF

# ===== VPS Optimize =====
# 网络调度与拥塞控制 (BBR + FQ 是绝配)
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
    sysctl -p >/dev/null
}

# 3. 硬件层面降载 (针对单核 VPS)
optimize_hardware() {
    echo "执行硬件级优化 (中断合并 + 卸载开启)..."
    
    # 关闭单核无意义的 irqbalance
    systemctl stop irqbalance 2>/dev/null || true
    systemctl disable irqbalance 2>/dev/null || true

    if ! command -v ethtool >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y ethtool >/dev/null 2>&1 || true
    fi

    # 获取主要网卡
    local interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|en|ens|enp)')
    for iface in $interfaces; do
        # 1. 尝试拉满 Ring Buffer
        local max_rx=$(ethtool -g "$iface" 2>/dev/null | grep -m 1 "RX:" | awk '{print $2}' || echo "0")
        if [[ "$max_rx" =~ ^[0-9]+$ ]] && [ "$max_rx" -gt 0 ]; then
            ethtool -G "$iface" rx "$max_rx" 2>/dev/null || true
        fi

        # 2. 开启自适应中断合并 (关键：减少 CPU 被网络包打断的次数)
        ethtool -C "$iface" adaptive-rx on 2>/dev/null || ethtool -C "$iface" rx-usecs 50 2>/dev/null || true

        # 3. 开启硬件卸载 (把计算任务交给网卡)
        ethtool -K "$iface" tso on gso on gro on 2>/dev/null || true
        
        # 4. 实时生效 FQ
        tc qdisc del dev "$iface" root 2>/dev/null || true
        tc qdisc add dev "$iface" root fq 2>/dev/null || true
    done
}

# 4. Hysteria2 守候服务
configure_hysteria() {
    if [ ! -f "/usr/local/bin/hysteria" ]; then
        echo -e "${BLUE}未检测到 Hysteria2，跳过服务配置。${PLAIN}"
        return
    fi

    echo -n "是否为落地机开启 Warp 依赖守护模式? [y/N]: "
    read -r is_warp < /dev/tty
    
    local wait_cmd=""
    if [[ "$is_warp" =~ ^[Yy]$ ]]; then
        wait_cmd="ExecStartPre=/bin/sh -c 'until ip addr show warp >/dev/null 2>&1; do sleep 2; done'"
    fi

    cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria Server Service (Optimized)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/lib/hysteria
${wait_cmd}
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=always
RestartSec=3s
# 给予高权限处理原始套接字
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    echo "Hysteria2 系统服务已更新。"
}

# 执行流程
cleanup_configs
write_sysctl
optimize_hardware
configure_hysteria

echo -e "${GREEN}===================================================="
echo -e "优化完成！当前状态："
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
echo -e "----------------------------------------------------"
echo -e "提示：FQ + BBR 已生效，单核硬件降载已完成。"
echo -e "如果修改了 Hysteria2 配置，请重启服务：systemctl restart hysteria-server"
echo -e "====================================================${PLAIN}"
