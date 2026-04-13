#!/bin/bash
set -e

# ====================================================
# 脚本功能：内核极致压榨 + 单核硬件降载 + Hysteria2 终极配置
# 优化重点：BBR + FQ-PIE + 128MB 缓冲区 + 中断合并 + 系统限额突破
# 适用场景：1000M 带宽 / 200-500ms 高延迟 / 单核 CPU
# ====================================================

SYSCTL_FILE="/etc/sysctl.conf"

cleanup_old_config() {
    echo "正在清理冲突配置并备份..."
    # 删除可能的第三方优化文件
    rm -f /etc/sysctl.d/99-vps-optimize.conf /etc/sysctl.d/99-bbr.conf /etc/sysctl.d/98-bbr.conf /etc/sysctl.d/99-netopt.conf

    # 备份当前配置
    cp -a "$SYSCTL_FILE" "${SYSCTL_FILE}.bak.$(date +%s)"

    # 清理 sysctl.conf 中与本项目冲突的旧条目
    sed -i '/# ===== VPS Optimize =====/,/# ===== End VPS Optimize =====/d' "$SYSCTL_FILE"
    
    # 彻底清理可能残留的单行配置
    local params=(
        "net.ipv4.tcp_congestion_control" "net.core.default_qdisc" "net.core.rmem_max" 
        "net.core.wmem_max" "net.ipv4.tcp_rmem" "net.ipv4.tcp_wmem" "net.ipv4.udp_mem"
        "net.ipv4.ipfrag_high_thresh" "net.ipv4.tcp_notsent_lowat" "net.ipv4.tcp_fastopen"
    )
    for param in "${params[@]}"; do
        sed -i "/^\s*${param}\s*=/d" "$SYSCTL_FILE"
    done
    echo "  - 已完成冲突项清理。"
}

write_final_sysctl_config() {
    echo "正在写入 128MB 缓冲区与极致压榨补丁..."

    cat >> "$SYSCTL_FILE" <<'EOF'

# ===== VPS Optimize =====
# --- 拥塞控制与队列 (BBR + FQ-PIE) ---
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr

# --- 128MB 超大缓冲区 (针对 1000M + 500ms 延迟) ---
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# --- 单核 CPU 专用 UDP 内存页优化 ---
net.ipv4.udp_mem = 262144 524288 786432
net.core.optmem_max = 262144

# --- UDP 分片重组深度优化 (防止丢包) ---
net.ipv4.ipfrag_high_thresh = 134217728
net.ipv4.ipfrag_low_thresh = 100663296
net.ipv4.ipfrag_time = 60

# --- 高延迟/长肥网络 TCP 精修 ---
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_frto = 2

# --- 并发能力补丁 ---
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 25

# --- 路径 MTU 与 Fast Open ---
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
# ===== End VPS Optimize =====
EOF

    sysctl --system >/dev/null
    echo "  - 内核参数应用成功。"
}

apply_system_limits() {
    echo "正在突破系统文件描述符限制 (ulimit)..."
    if ! grep -q "soft nofile 512000" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf <<EOF
* soft nofile 512000
* hard nofile 512000
root soft nofile 512000
root hard nofile 512000
EOF
    fi
    echo "  - ulimit 已提升至 512000。"
}

optimize_single_core_hardware() {
    echo "正在执行单核硬件降载 (中断合并 + Ring Buffer)..."
    # 停用并删除多核中断均衡服务
    systemctl stop irqbalance 2>/dev/null || true
    systemctl disable irqbalance 2>/dev/null || true
    
    # 自动安装 ethtool
    if ! command -v ethtool >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y ethtool >/dev/null 2>&1 || true
    fi

    # 遍历物理网卡
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|en|ens|enp)')
    for iface in $interfaces; do
        # 扩容硬件 Ring Buffer
        MAX_RX=$(ethtool -g "$iface" 2>/dev/null | grep -m 1 "RX:" | awk '{print $2}' || echo "0")
        if [ "$MAX_RX" != "0" ] && [ "$MAX_RX" != "n/a" ]; then
            ethtool -G "$iface" rx "$MAX_RX" 2>/dev/null || true
        fi

        # 开启中断合并，减少单核 CPU 压力
        if ethtool -C "$iface" adaptive-rx on 2>/dev/null; then
            echo "  - $iface: 开启自适应中断合并"
        else
            ethtool -C "$iface" rx-usecs 50 tx-usecs 50 2>/dev/null || true
            echo "  - $iface: 开启静态 50us 中断合并"
        fi

        # 开启硬件分段卸载
        ethtool -K "$iface" gso on tso on gro on 2>/dev/null || true
    done
}

apply_live_qdisc() {
    echo "正在实时应用 FQ-PIE 队列规则..."
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E '^(eth|en|ens|enp|eno|warp|wg|tun)' || true)
    for iface in $interfaces; do
        [ "$iface" = "lo" ] && continue
        tc qdisc del dev "$iface" root 2>/dev/null || true
        if ! tc qdisc replace dev "$iface" root fq_pie 2>/dev/null; then
            tc qdisc replace dev "$iface" root fq 2>/dev/null || true
            echo "  - $iface: 已应用 fq (内核不支持 fq_pie)"
        else
            echo "  - $iface: 已应用 fq_pie"
        fi
    done
}

configure_hysteria_service() {
    echo "----------------------------------------------------"
    # 自动搜索 hysteria 路径
    HY_BIN=$(command -v hysteria || echo "/usr/local/bin/hysteria")

    if [ -f "$HY_BIN" ]; then
        echo "检测到 Hysteria2: $HY_BIN"
        # 强制从终端读取，防止在管道运行中被跳过
        read -p "是否开启【增强守候模式】(循环等待 warp 网卡)？[y/n]: " is_warp < /dev/tty

        if [[ "$is_warp" == "y" || "$is_warp" == "Y" ]]; then
            WAIT_LOGIC="ExecStartPre=/bin/sh -c 'until ip addr show warp >/dev/null 2>&1; do sleep 2; done'"
            DESC_SUFFIX="(Warp Wait)"
        else
            WAIT_LOGIC=""
            DESC_SUFFIX="(Standard)"
        fi

        cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria Server Service ${DESC_SUFFIX}
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
${WAIT_LOGIC}
ExecStart=${HY_BIN} server --config /etc/hysteria/config.yaml
WorkingDirectory=/var/lib/hysteria
User=root
Environment=HYSTERIA_LOG_LEVEL=info
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=0
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
        mkdir -p /var/lib/hysteria
        systemctl daemon-reload
        echo "  - Hysteria2 服务配置已更新。"
    else
        echo "  - [跳过] 未在系统路径中找到 Hysteria2 主程序。"
    fi
}

show_result() {
    echo "===================================================="
    echo "优化汇总报告："
    echo " - 拥塞算法: $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo " - 默认队列: $(sysctl -n net.core.default_qdisc)"
    echo " - 最大缓冲区: $(sysctl -n net.core.rmem_max | awk '{print $1/1024/1024 " MB"}')"
    echo " - 文件描述符: $(ulimit -n)"
    echo "----------------------------------------------------"
    echo "单核极致压榨优化已完成。强烈建议重启系统以使硬件配置生效。"
    echo "===================================================="
}

# --- 执行流 ---
cleanup_old_config
write_final_sysctl_config
apply_system_limits
optimize_single_core_hardware
apply_live_qdisc
configure_hysteria_service
show_result
