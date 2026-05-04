#!/bin/bash
set -e

# ====================================================
# 脚本功能：内核极致压榨 + 单核硬件降载 + Hysteria2 终极配置 + OCI/ARM64 专属优化
# 优化重点：BBR + FQ + 128MB 缓冲区 + 系统限额突破 + 日志减负 + 权限修复
# 适用场景：1000M 带宽 / 200-500ms 高延迟 / 单核或 ARM64 云主机
# 版本：V2.1 (修复 ACME 证书读写权限问题)
# ====================================================

SYSCTL_FILE="/etc/sysctl.conf"
LIMITS_FILE="/etc/security/limits.conf"

echo -e "\n🚀 正在启动 VPS 极速网络全能优化脚本 V2.1...\n"

# ================= 1. 基础环境与模块准备 =================
prepare_env() {
    echo "正在加载必要的内核模块 (BBR, Conntrack)..."
    modprobe tcp_bbr 2>/dev/null || true
    modprobe nf_conntrack 2>/dev/null || true
    
    # 确保 systemd-journald 服务正常
    if systemctl is-active --quiet systemd-journald; then
        echo "正在优化系统日志体积，防止占满磁盘..."
        journalctl --vacuum-time=7d >/dev/null 2>&1 || true
        journalctl --vacuum-size=500M >/dev/null 2>&1 || true
        # 修改 journald 配置文件限制
        sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf 2>/dev/null || true
        systemctl restart systemd-journald 2>/dev/null || true
    fi
}

# ================= 2. 清理旧配置 =================
cleanup_old_config() {
    echo "正在清理冲突配置并备份..."
    rm -f /etc/sysctl.d/99-vps-optimize.conf /etc/sysctl.d/99-bbr.conf /etc/sysctl.d/98-bbr.conf /etc/sysctl.d/99-netopt.conf

    cp -a "$SYSCTL_FILE" "${SYSCTL_FILE}.bak.$(date +%s)"
    sed -i '/# ===== VPS Optimize V2 =====/,/# ===== End VPS Optimize V2 =====/d' "$SYSCTL_FILE"
    sed -i '/# ===== VPS Optimize =====/,/# ===== End VPS Optimize =====/d' "$SYSCTL_FILE"
    
    local params=(
        "net.ipv4.tcp_congestion_control" "net.core.default_qdisc" "net.core.rmem_max" 
        "net.core.wmem_max" "net.ipv4.tcp_rmem" "net.ipv4.tcp_wmem" "net.ipv4.udp_mem"
        "net.ipv4.ipfrag_high_thresh" "net.ipv4.tcp_notsent_lowat" "net.ipv4.tcp_fastopen"
        "net.netfilter.nf_conntrack_max" "net.ipv4.tcp_mtu_probing"
    )
    for param in "${params[@]}"; do
        sed -i "/^\s*${param}\s*=/d" "$SYSCTL_FILE"
    done
    echo "  - 已完成冲突项清理。"
}

# ================= 3. 写入极限优化网络参数 =================
write_final_sysctl_config() {
    echo "正在写入 128MB 缓冲区与极致压榨补丁..."

    cat >> "$SYSCTL_FILE" <<'EOF'

# ===== VPS Optimize V2 =====
# --- 拥塞控制与队列 (BBR + FQ，极速首选) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- 128MB 超大缓冲区 (针对 1000M + 500ms 高延迟跨境线路) ---
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# --- 单核/ARM 专用 UDP 内存页优化 (提升 Hysteria2 等协议性能) ---
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

# --- 连接追踪与并发能力补丁 (防止 table full 丢包) ---
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 25

# --- 路径 MTU 与 Fast Open (解决黑洞与加速握手) ---
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
# ===== End VPS Optimize V2 =====
EOF

    sysctl --system >/dev/null 2>&1
    echo "  - 内核参数应用成功。"
}

# ================= 4. 解除系统进程与文件限制 =================
apply_system_limits() {
    echo "正在突破系统文件描述符限制 (ulimit)..."
    sed -i '/soft nofile/d' "$LIMITS_FILE"
    sed -i '/hard nofile/d' "$LIMITS_FILE"
    
    cat >> "$LIMITS_FILE" <<EOF
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    echo "  - ulimit 已提升至 1048576。"
}

# ================= 5. 网卡硬件降载优化 =================
optimize_single_core_hardware() {
    echo "正在执行单核硬件降载 (中断合并 + Ring Buffer)..."
    systemctl stop irqbalance 2>/dev/null || true
    systemctl disable irqbalance 2>/dev/null || true
    
    if ! command -v ethtool >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y ethtool >/dev/null 2>&1 || true
    fi

    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|en|ens|enp)')
    for iface in $interfaces; do
        MAX_RX=$(ethtool -g "$iface" 2>/dev/null | grep -m 1 "RX:" | awk '{print $2}' || echo "0")
        if [ "$MAX_RX" != "0" ] && [ "$MAX_RX" != "n/a" ]; then
            ethtool -G "$iface" rx "$MAX_RX" 2>/dev/null || true
        fi

        if ethtool -C "$iface" adaptive-rx on 2>/dev/null; then
            echo "  - $iface: 开启自适应中断合并"
        else
            ethtool -C "$iface" rx-usecs 50 tx-usecs 50 2>/dev/null || true
            echo "  - $iface: 开启静态 50us 中断合并"
        fi
        ethtool -K "$iface" gso on tso on gro on 2>/dev/null || true
    done
}

# ================= 6. 实时应用 Qdisc =================
apply_live_qdisc() {
    echo "正在实时应用 FQ 队列规则..."
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E '^(eth|en|ens|enp|eno|warp|wg|tun)' || true)
    for iface in $interfaces; do
        [ "$iface" = "lo" ] && continue
        tc qdisc del dev "$iface" root 2>/dev/null || true
        # 优先使用 fq，不支持则回退 fq_pie
        if ! tc qdisc replace dev "$iface" root fq 2>/dev/null; then
            tc qdisc replace dev "$iface" root fq_pie 2>/dev/null || true
            echo "  - $iface: 已应用 fq_pie (内核或网卡不支持 fq)"
        else
            echo "  - $iface: 已应用 fq"
        fi
    done
}

# ================= 7. Hysteria2 智能守护 (修复权限版) =================
configure_hysteria_service() {
    echo "----------------------------------------------------"
    HY_BIN=$(command -v hysteria || echo "/usr/local/bin/hysteria")

    if [ -f "$HY_BIN" ]; then
        echo "检测到 Hysteria2: $HY_BIN"
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
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        # 确保目录存在并且赋予正常 root 权限 (修复 ACME 报错)
        mkdir -p /var/lib/hysteria/acme
        mkdir -p /etc/hysteria/acme
        chown -R root:root /var/lib/hysteria /etc/hysteria 2>/dev/null || true
        chmod -R 755 /var/lib/hysteria /etc/hysteria 2>/dev/null || true

        systemctl daemon-reload
        echo "  - Hysteria2 服务配置已更新 (已注入 LimitNOFILE 限制解除并修复 ACME 权限)。"
    else
        echo "  - [跳过] 未在系统路径中找到 Hysteria2 主程序。"
    fi
}

# ================= 8. 输出报告 =================
show_result() {
    echo "===================================================="
    echo "✅ 优化汇总报告："
    echo " - 拥塞算法: $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo " - 默认队列: $(sysctl -n net.core.default_qdisc)"
    echo " - 最大缓冲区: $(sysctl -n net.core.rmem_max | awk '{print $1/1024/1024 " MB"}')"
    echo " - 连接追踪并发: $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "未加载")"
    echo " - 系统描述符: $(ulimit -n)"
    echo "----------------------------------------------------"
    echo "🎉 全能网络与系统优化已完成！强烈建议 【重启系统 (reboot)】 以使部分硬件与内核配置彻底生效。"
    echo "===================================================="
}

# --- 执行流 ---
prepare_env
cleanup_old_config
write_final_sysctl_config
apply_system_limits
optimize_single_core_hardware
apply_live_qdisc
configure_hysteria_service
show_result
