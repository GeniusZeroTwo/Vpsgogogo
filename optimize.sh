#!/bin/bash
set -e

# ====================================================
# 脚本功能：内核基础优化 + TCP 并发/Fast Open 优化 + Hysteria2 交互守候
# 适用系统：Debian 11+, Ubuntu 20.04+ (Root 权限执行)
# 特点：
# 1. 先清理旧的拥塞控制/队列配置，再写入 bbr + fq_pie
# 2. 支持通过 curl | bash 方式直接执行，不落本地脚本文件
# ====================================================

OPT_FILE="/etc/sysctl.d/99-vps-optimize.conf"

cleanup_old_cc_qdisc_config() {
    echo "正在清理旧的拥塞控制与队列配置..."

    # 先删除本脚本历史文件，避免重复
    rm -f /etc/sysctl.d/99-vps-optimize.conf
    rm -f /etc/sysctl.d/99-bbr.conf
    rm -f /etc/sysctl.d/98-bbr.conf
    rm -f /etc/sysctl.d/99-netopt.conf

    # 需要清理的文件范围
    files=""
    [ -f /etc/sysctl.conf ] && files="$files /etc/sysctl.conf"
    for f in /etc/sysctl.d/*.conf; do
        [ -e "$f" ] && files="$files $f"
    done

    for f in $files; do
        # 跳过我们即将写入的目标文件
        [ "$f" = "$OPT_FILE" ] && continue

        # 如果文件里存在旧配置，就删掉对应行
        if grep -Eq '^\s*net\.ipv4\.tcp_congestion_control\s*=|^\s*net\.core\.default_qdisc\s*=' "$f" 2>/dev/null; then
            cp -a "$f" "${f}.bak.$(date +%s)"
            sed -i \
                -e '/^\s*net\.ipv4\.tcp_congestion_control\s*=/d' \
                -e '/^\s*net\.core\.default_qdisc\s*=/d' \
                "$f"
            echo "  - 已清理: $f"
        fi
    done
}

write_new_sysctl_config() {
    echo "正在写入新的内核网络参数..."
    cat > "$OPT_FILE" <<'EOF'
# --- 基础拥塞控制 ---
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr

# --- 路径 MTU 探测 ---
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.tcp_mtu_probing = 1

# --- TCP Fast Open (TFO) ---
net.ipv4.tcp_fastopen = 3

# --- 提升并发处理能力 ---
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 8192

# --- TCP 缓冲区 ---
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# --- 连接行为优化 ---
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fin_timeout = 25
EOF

    sysctl --system >/dev/null
    echo "  - 内核参数已应用。"
}

apply_live_qdisc() {
    echo "正在配置当前网卡队列规则 (FQ-PIE)..."

    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E '^(eth|en|ens|enp|eno|warp|wg|tun)' || true)

    for iface in $interfaces; do
        # 跳过 lo
        [ "$iface" = "lo" ] && continue

        # 尝试先删除旧 root qdisc，再重新挂 fq_pie
        tc qdisc del dev "$iface" root 2>/dev/null || true
        tc qdisc replace dev "$iface" root fq_pie 2>/dev/null || true

        current_qdisc=$(tc qdisc show dev "$iface" 2>/dev/null | head -n1 || true)
        echo "  - $iface => ${current_qdisc:-未能读取 qdisc 状态}"
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
    echo "当前结果："
    sysctl net.core.default_qdisc
    sysctl net.ipv4.tcp_congestion_control
    echo "----------------------------------------------------"
    tc qdisc show
    echo "===================================================="
    echo "所有优化已完成！"
    echo "您可以执行: systemctl restart hysteria-server"
    echo "===================================================="
}

cleanup_old_cc_qdisc_config
write_new_sysctl_config
apply_live_qdisc
configure_hysteria_service
show_result
