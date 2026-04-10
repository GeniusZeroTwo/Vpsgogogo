#!/bin/bash
set -e

# ====================================================
# 脚本功能：内核极致优化 + 单核硬件降载 + Hysteria2 守候
# 优化重点：BBR + FQ-PIE + 128MB 超大缓冲区 + 中断合并 (保单核 CPU)
# 适用系统：Debian 11+, Ubuntu 20.04+ (Root 权限执行)
# ====================================================

SYSCTL_FILE="/etc/sysctl.conf"

cleanup_old_cc_qdisc_config() {
    echo "正在清理旧的拥塞控制与队列配置..."

    # 删除旧脚本可能留下的配置文件
    rm -f /etc/sysctl.d/99-vps-optimize.conf
    rm -f /etc/sysctl.d/99-bbr.conf
    rm -f /etc/sysctl.d/98-bbr.conf
    rm -f /etc/sysctl.d/99-netopt.conf

    # 备份 sysctl.conf
    cp -a "$SYSCTL_FILE" "${SYSCTL_FILE}.bak.$(date +%s)"

    # 清理 /etc/sysctl.conf 里旧值
    sed -i \
        -e '/^\s*net\.ipv4\.tcp_congestion_control\s*=/d' \
        -e '/^\s*net\.core\.default_qdisc\s*=/d' \
        -e '/^\s*net\.ipv4\.ip_no_pmtu_disc\s*=/d' \
        -e '/^\s*net\.ipv4\.tcp_mtu_probing\s*=/d' \
        -e '/^\s*net\.ipv4\.tcp_fastopen\s*=/d' \
        -e '/^\s*net\.core\.somaxconn\s*=/d' \
        -e '/^\s*net\.core\.netdev_max_backlog\s*=/d' \
        -e '/^\s*net\.ipv4\.tcp_max_syn_backlog\s*=/d' \
        -e '/^\s*net\.core\.rmem_max\s*=/d' \
        -e '/^\s*net\.core\.wmem_max\s*=/d' \
        -e '/^\s*net\.ipv4\.tcp_rmem\s*=/d' \
        -e '/^\s*net\.ipv4\.tcp_wmem\s*=/d' \
        -e '/^\s*net\.ipv4\.udp_rmem_min\s*=/d' \
        -e '/^\s*net\.ipv4\.udp_wmem_min\s*=/d' \
        -e '/^\s*net\.ipv4\.udp_mem\s*=/d' \
        -e '/^\s*net\.core\.optmem_max\s*=/d' \
        -e '/^\s*net\.ipv4\.tcp_slow_start_after_idle\s*=/d' \
        -e '/^\s*net\.ipv4\.tcp_notsent_lowat\s*=/d' \
        -e '/^\s*net\.ipv4\.tcp_fin_timeout\s*=/d' \
        -e '/^# ===== VPS Optimize =====$/d' \
        -e '/^# ===== End VPS Optimize =====$/d' \
        "$SYSCTL_FILE"

    echo "  - 已清理旧配置: $SYSCTL_FILE"

    # 清理 /etc/sysctl.d/*.conf 里可能覆盖的旧值
    for f in /etc/sysctl.d/*.conf; do
        [ -e "$f" ] || continue
        if grep -Eq '^\s*net\.ipv4\.tcp_congestion_control\s*=|^\s*net\.core\.default_qdisc\s*=' "$f" 2>/dev/null; then
            cp -a "$f" "${f}.bak.$(date +%s)"
            sed -i \
                -e '/^\s*net\.ipv4\.tcp_congestion_control\s*=/d' \
                -e '/^\s*net\.core\.default_qdisc\s*=/d' \
                "$f"
            echo "  - 已清理干扰项: $f"
        fi
    done
}

write_new_sysctl_config() {
    echo "正在写入全新的内核网络参数 (BBR + FQ-PIE, 128MB 进阶防抖) ..."

    cat >> "$SYSCTL_FILE" <<'EOF'

# ===== VPS Optimize =====
# --- 基础拥塞控制与队列管理 ---
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr

# --- 突破 UDP 内存页极限 (专为单核跑 QUIC 保驾护航) ---
net.ipv4.udp_mem = 262144 524288 786432
net.core.optmem_max = 262144

# --- 针对 1000M + 高延迟的 128MB 超大缓冲区 ---
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# --- 提升并发处理能力与抗抖动 ---
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 16384

# --- TCP 高级属性调优 (长肥网络适用) ---
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fin_timeout = 25
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1

# --- 路径 MTU 探测与 Fast Open ---
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
# ===== End VPS Optimize =====
EOF

    sysctl --system >/dev/null
    echo "  - 内核参数已应用。"
}

apply_live_qdisc() {
    echo "正在配置当前网卡队列规则 (FQ-PIE)..."

    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E '^(eth|en|ens|enp|eno|warp|wg|tun)' || true)

    for iface in $interfaces; do
        [ "$iface" = "lo" ] && continue

        # 尝试切换为 fq_pie
        tc qdisc del dev "$iface" root 2>/dev/null || true
        if ! tc qdisc replace dev "$iface" root fq_pie 2>/dev/null; then
            # 如果内核不支持 fq_pie，自动降级为 fq
            tc qdisc replace dev "$iface" root fq 2>/dev/null || true
            echo "  - $iface => 检测到内核不支持 fq_pie，已自动降级回退至 fq"
        else
            current_qdisc=$(tc qdisc show dev "$iface" 2>/dev/null | head -n1 || true)
            echo "  - $iface => ${current_qdisc:-配置成功}"
        fi
    done
}

optimize_single_core_hardware() {
    echo "正在执行单核专属硬件降载 (中断合并 + Ring Buffer 扩容)..."

    # 1. 停用 irqbalance (单核无须中断均衡，省下 CPU 给进程)
    systemctl stop irqbalance 2>/dev/null || true
    systemctl disable irqbalance 2>/dev/null || true
    
    # 2. 检查并安装 ethtool
    if ! command -v ethtool >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y ethtool >/dev/null 2>&1 || true
    fi

    # 3. 针对物理/虚拟网卡硬件优化
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|en|ens|enp)')
    for iface in $interfaces; do
        # 扩容 Ring Buffer，防止突发丢包
        MAX_RX=$(ethtool -g "$iface" 2>/dev/null | grep -m 1 "RX:" | awk '{print $2}' || echo "0")
        if [ "$MAX_RX" != "0" ] && [ "$MAX_RX" != "n/a" ]; then
            ethtool -G "$iface" rx "$MAX_RX" 2>/dev/null || true
            echo "  - $iface: 接收队列 (RX) 已拉满至 $MAX_RX"
        fi

        # 核心：网卡中断合并 (大幅降低单核 CPU 中断占用)
        if ethtool -C "$iface" adaptive-rx on 2>/dev/null; then
            echo "  - $iface: 已开启网卡自适应中断合并"
        else
            ethtool -C "$iface" rx-usecs 50 tx-usecs 50 2>/dev/null || true
            echo "  - $iface: 已强制开启 50us 静态中断合并"
        fi

        # 硬件卸载全开
        ethtool -K "$iface" gso on tso on gro on 2>/dev/null || true
    done
}

configure_hysteria_service() {
    echo "----------------------------------------------------"
    if [ -f "/usr/local/bin/hysteria" ]; then
        echo "检测到 Hysteria2 已安装，准备配置 Systemd 服务。"
        echo "是否开启【增强守候模式】？(循环等待 warp 网卡加载，适合落地机)"

        read -r -p "开启请输入 y，关闭请输入 n [y/n]: " is_warp < /dev/tty

        if [[ "$is_warp" == "y" || "$is_warp" == "Y" ]]; then
            WAIT_LOGIC="ExecStartPre=/bin/sh -c 'until ip addr show warp >/dev/null 2>&1; do sleep 2; done'"
            DESC_SUFFIX="(带 Warp 等待逻辑)"
            echo "--> 已确认：开启增强守候。"
        else
            WAIT_LOGIC=""
            DESC_SUFFIX="(标准模式)"
            echo "--> 已确认：关闭增强守候。"
        fi

        cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria Server Service ${DESC_SUFFIX}
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
${WAIT_LOGIC}
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
WorkingDirectory=/var/lib/hysteria
User=hysteria
Group=hysteria
Environment=HYSTERIA_LOG_LEVEL=info
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=0
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

        mkdir -p /var/lib/hysteria

        if id hysteria >/dev/null 2>&1; then
            chown -R hysteria:hysteria /var/lib/hysteria
        fi

        systemctl daemon-reload
        echo "  - Hysteria2 服务配置完成。"
    else
        echo "  - 未检测到 Hysteria2 主程序，跳过服务配置。"
    fi
}

show_result() {
    echo "===================================================="
    echo "优化结果汇总："
    sysctl net.core.default_qdisc
    sysctl net.ipv4.tcp_congestion_control
    sysctl net.core.rmem_max
    echo "----------------------------------------------------"
    echo "当前网卡队列状态 (qdisc):"
    tc qdisc show | grep -E 'fq_pie|fq|bbr' || tc qdisc show
    echo "===================================================="
    echo "单核硬件降载与 128MB (FQ-PIE) 网络优化已全部完成！"
    echo "建议提示：如果更改了 Hysteria2 服务配置，请手动执行："
    echo "systemctl restart hysteria-server"
    echo "===================================================="
}

# 执行流
cleanup_old_cc_qdisc_config
write_new_sysctl_config
apply_live_qdisc
optimize_single_core_hardware
configure_hysteria_service
show_result
