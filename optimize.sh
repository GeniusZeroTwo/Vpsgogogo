#!/bin/bash
set -e

# ====================================================
# 脚本功能：内核基础优化 + TCP 并发/Fast Open 优化 + Hysteria2 交互守候
# 优化重点：BBR + FQ (BBR 的官方最佳搭档，提供硬件级 Pacing)
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
    echo "正在写入新的内核网络参数到 /etc/sysctl.conf (BBR + FQ) ..."

    cat >> "$SYSCTL_FILE" <<'EOF'

# ===== VPS Optimize =====
# --- 基础拥塞控制与队列管理 ---
net.core.default_qdisc = fq
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
# ===== End VPS Optimize =====
EOF

    sysctl --system >/dev/null
    echo "  - 内核参数已应用。"
}

apply_live_qdisc() {
    echo "正在配置当前网卡队列规则 (FQ)..."

    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E '^(eth|en|ens|enp|eno|warp|wg|tun)' || true)

    for iface in $interfaces; do
        [ "$iface" = "lo" ] && continue

        # 尝试切换为 fq
        tc qdisc del dev "$iface" root 2>/dev/null || true
        if ! tc qdisc replace dev "$iface" root fq 2>/dev/null; then
            echo "  - $iface => 配置 fq 失败，请检查内核版本"
        else
            current_qdisc=$(tc qdisc show dev "$iface" 2>/dev/null | head -n1 || true)
            echo "  - $iface => ${current_qdisc:-配置成功}"
        fi
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
    echo "----------------------------------------------------"
    echo "当前网卡队列状态 (qdisc):"
    tc qdisc show | grep -E 'fq|bbr' || tc qdisc show
    echo "===================================================="
    echo "所有优化已完成！"
    echo "建议提示：如果更改了 Hysteria2 服务配置，请手动执行："
    echo "systemctl restart hysteria-server"
    echo "===================================================="
}

# 执行流
cleanup_old_cc_qdisc_config
write_new_sysctl_config
apply_live_qdisc
configure_hysteria_service
show_result
