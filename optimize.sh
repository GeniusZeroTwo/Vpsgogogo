#!/bin/bash
set -e

# ====================================================
# 脚本功能：内核极致压榨 + 硬件智能降载 + Hysteria2 终极配置 + OCI/ARM64 专属优化 + 防火墙全通
# 优化重点：BBR + FQ + 智能动态缓冲区 + 系统限额突破 + 日志减负 + 权限修复 + 端口永久放行
# 适用场景：1000M 带宽 / 全配置云主机自动适应 / 真实端到端延迟感知
# 版本：V3.5 (真实本地延迟追踪与 BDP 自适应调优版)
# ====================================================

SYSCTL_FILE="/etc/sysctl.conf"
LIMITS_FILE="/etc/security/limits.conf"

echo -e "\n🚀 正在启动 VPS 极速网络全能优化脚本 V3.5 (真实本地延迟追踪版)...\n"

# ================= 0. 硬件环境自动侦测 =================
detect_hardware() {
    echo "正在侦测硬件配置以进行动态适应..."
    TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc)
    ARCH=$(uname -m)

    # 1. 内存分级逻辑
    if [ "$TOTAL_MEM_MB" -lt 1024 ]; then
        MEM_LEVEL="低配 (< 1GB)"
        RMEM_MAX=16777216
        WMEM_MAX=16777216
        UDP_MEM="65536 131072 262144"
        CONNTRACK_MAX=262144
    elif [ "$TOTAL_MEM_MB" -lt 4096 ]; then
        MEM_LEVEL="中配 (1GB - 4GB)"
        RMEM_MAX=67108864
        WMEM_MAX=67108864
        UDP_MEM="131072 262144 524288"
        CONNTRACK_MAX=524288
    else
        MEM_LEVEL="高配 (>= 4GB)"
        RMEM_MAX=134217728
        WMEM_MAX=134217728
        UDP_MEM="262144 524288 786432"
        CONNTRACK_MAX=1048576
    fi
    
    RMEM_DEFAULT=$(( RMEM_MAX / 4 ))
    WMEM_DEFAULT=$(( WMEM_MAX / 4 ))
    FRAG_LOW=$(( RMEM_MAX * 3 / 4 ))

    echo "  - 架构: $ARCH"
    echo "  - 核心数: $CPU_CORES Core(s)"
    echo "  - 总内存: $TOTAL_MEM_MB MB ($MEM_LEVEL)"
    echo "  - 决定的最大缓冲区: $(( RMEM_MAX / 1024 / 1024 )) MB"
}

# ================= 1. 真实端到端网络延迟探测 =================
detect_network_latency() {
    echo "----------------------------------------------------"
    echo "正在探测至您本地的真实物理延迟，以决定最佳 BDP (带宽延迟乘积) 策略..."
    
    LATENCY_RAW="0"
    # 获取当前连接 SSH 的客户端真实 IP
    CLIENT_IP=$(echo $SSH_CLIENT | awk '{print $1}')

    if [ -n "$CLIENT_IP" ]; then
        echo "  - 探测到您当前的 SSH 客户端真实 IP 为: $CLIENT_IP"
        echo "  - 正在尝试对您的本地 IP 进行 ICMP 测速..."
        # 测试 3 次，超时设为 5 秒，提取平均延迟时间
        LATENCY_RAW=$(ping -c 3 -w 5 "$CLIENT_IP" 2>/dev/null | awk -F'/' 'END{print ($4=="" ? 0 : $4)}' || echo "0")
    fi

    LATENCY_INT=${LATENCY_RAW%.*}

    # 如果无法 ping 通本地 (很可能是家用路由器或运营商禁 Ping)
    if [ "$LATENCY_INT" -eq 0 ]; then
        echo "  - ⚠️ 无法 PING 通您的本地 IP (可能被本地路由器或光猫的防火墙拦截)。"
        echo "  - 🔄 正在触发替代方案：PING 阿里云公共 DNS (223.5.5.5) 模拟回国链路真实延迟..."
        LATENCY_RAW=$(ping -c 3 -w 5 223.5.5.5 2>/dev/null | awk -F'/' 'END{print ($4=="" ? 0 : $4)}' || echo "0")
        LATENCY_INT=${LATENCY_RAW%.*}
    else
        echo "  - ✅ 成功测定到您本地的真实物理延迟！"
    fi

    # 根据测得的真实延迟进行策略分发
    if [ "$LATENCY_INT" -eq 0 ]; then
        LATENCY_LEVEL="未知/完全阻断 (启用跨国高延迟安全模式)"
        LATENCY_INT=200
        DYN_LOWAT=262144
        DYN_ADV_WIN=1
        DYN_KEEPALIVE_PROBES=6
    elif [ "$LATENCY_INT" -gt 150 ]; then
        LATENCY_LEVEL="跨国长肥网络 (>150ms)"
        DYN_LOWAT=262144    # 极高延迟：256KB 水位线，确保管道内有充足数据，抗高延迟卡顿
        DYN_ADV_WIN=1       # 大量缓存用于网络窗口，支撑远洋传输吞吐量
        DYN_KEEPALIVE_PROBES=6
    elif [ "$LATENCY_INT" -gt 60 ]; then
        LATENCY_LEVEL="区域中等延迟 (60-150ms)"
        DYN_LOWAT=131072    # 中等延迟：128KB 水位线，平衡吞吐与响应速度
        DYN_ADV_WIN=1
        DYN_KEEPALIVE_PROBES=5
    else
        LATENCY_LEVEL="同城/优质低延迟链路 (<60ms)"
        DYN_LOWAT=16384     # 低延迟：恢复 16KB 严格水位，防缓冲区臃肿，游戏/语音防跳Ping
        DYN_ADV_WIN=2       # 减小无意义的网络窗口开销，节省内核内存
        DYN_KEEPALIVE_PROBES=4
    fi

    echo "  - 最终测定延迟: ${LATENCY_RAW} ms [归类: $LATENCY_LEVEL]"
    echo "  - 动态策略分配: Lowat=${DYN_LOWAT}, WinScale=${DYN_ADV_WIN}"
    echo "----------------------------------------------------"
}

# ================= 2. 基础环境与模块准备 =================
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

# ================= 3. 清理旧配置 =================
cleanup_old_config() {
    echo "正在清理冲突配置并备份..."
    rm -f /etc/sysctl.d/99-vps-optimize.conf /etc/sysctl.d/99-bbr.conf /etc/sysctl.d/98-bbr.conf /etc/sysctl.d/99-netopt.conf

    cp -a "$SYSCTL_FILE" "${SYSCTL_FILE}.bak.$(date +%s)"
    sed -i '/# ===== VPS Optimize V2 =====/,/# ===== End VPS Optimize V2 =====/d' "$SYSCTL_FILE"
    sed -i '/# ===== VPS Optimize V3 =====/,/# ===== End VPS Optimize V3 =====/d' "$SYSCTL_FILE"
    sed -i '/# ===== VPS Optimize V3.3 =====/,/# ===== End VPS Optimize V3.3 =====/d' "$SYSCTL_FILE"
    sed -i '/# ===== VPS Optimize V3.4 =====/,/# ===== End VPS Optimize V3.4 =====/d' "$SYSCTL_FILE"
    sed -i '/# ===== VPS Optimize V3.5 =====/,/# ===== End VPS Optimize V3.5 =====/d' "$SYSCTL_FILE"
    sed -i '/# ===== VPS Optimize =====/,/# ===== End VPS Optimize =====/d' "$SYSCTL_FILE"
    
    local params=(
        "net.ipv4.tcp_congestion_control" "net.core.default_qdisc" "net.core.rmem_max" 
        "net.core.wmem_max" "net.ipv4.tcp_rmem" "net.ipv4.tcp_wmem" "net.ipv4.udp_mem"
        "net.ipv4.ipfrag_high_thresh" "net.ipv4.tcp_notsent_lowat" "net.ipv4.tcp_fastopen"
        "net.netfilter.nf_conntrack_max" "net.ipv4.tcp_mtu_probing" "net.ipv4.tcp_ecn"
        "net.ipv4.tcp_adv_win_scale"
    )
    for param in "${params[@]}"; do
        sed -i "/^\s*${param}\s*=/d" "$SYSCTL_FILE"
    done
    echo "  - 已完成冲突项清理。"
}

# ================= 4. 写入极限优化网络参数 =================
write_final_sysctl_config() {
    echo "正在根据硬件配置及真实延迟测定 (${LATENCY_INT}ms) 写入系统内核参数..."

    cat >> "$SYSCTL_FILE" <<EOF

# ===== VPS Optimize V3.5 (真实本地延迟版) =====
# --- 拥塞控制与队列 (BBR + FQ，极速首选) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- 动态计算网络缓冲区 ---
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.core.rmem_default = $RMEM_DEFAULT
net.core.wmem_default = $WMEM_DEFAULT
net.ipv4.tcp_rmem = 4096 87380 $RMEM_MAX
net.ipv4.tcp_wmem = 4096 65536 $WMEM_MAX
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# --- 专用 UDP 内存页优化 ---
net.ipv4.udp_mem = $UDP_MEM
net.core.optmem_max = 262144

# --- UDP 分片重组深度优化 ---
net.ipv4.ipfrag_high_thresh = $RMEM_MAX
net.ipv4.ipfrag_low_thresh = $FRAG_LOW
net.ipv4.ipfrag_time = 60

# --- 基于端到端真实延迟感知的防抖动 TCP 精修 ---
net.ipv4.tcp_window_scaling = 1
# [动态应用] 接收窗口比例分配 (高延迟1，低延迟2)
net.ipv4.tcp_adv_win_scale = $DYN_ADV_WIN
net.ipv4.tcp_slow_start_after_idle = 0
# [动态应用] Notsent 水位线，兼顾跨国高吞吐与防低延迟跳Ping (Bufferbloat)
net.ipv4.tcp_notsent_lowat = $DYN_LOWAT

# --- 防丢包与断流核心修补 ---
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 2
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_timestamps = 1

# --- 连接追踪、并发与超时防卡死 ---
net.netfilter.nf_conntrack_max = $CONNTRACK_MAX
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 25

# --- NAT 幽灵断线保活修复 ---
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = $DYN_KEEPALIVE_PROBES
net.ipv4.tcp_keepalive_intvl = 15

# --- 路径 MTU 与 Fast Open ---
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_fastopen = 1
# ===== End VPS Optimize V3.5 =====
EOF

    sysctl --system >/dev/null 2>&1
    echo "  - 内核参数应用成功 (真实延迟特化规则已注入)。"
}

# ================= 5. 解除系统进程与文件限制 =================
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

# ================= 6. 网卡硬件智能调优 =================
optimize_hardware_interrupts() {
    echo "正在执行硬件中断调优..."
    
    if [ "$CPU_CORES" -gt 1 ]; then
        echo "  - 探测到多核处理器 ($CPU_CORES Cores) -> 开启 irqbalance 平衡中断负载。"
        if ! command -v irqbalance >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y irqbalance >/dev/null 2>&1 || true
        fi
        systemctl enable irqbalance 2>/dev/null || true
        systemctl start irqbalance 2>/dev/null || true
    else
        echo "  - 探测到单核处理器 (1 Core) -> 停用 irqbalance 减少自身消耗。"
        systemctl stop irqbalance 2>/dev/null || true
        systemctl disable irqbalance 2>/dev/null || true
    fi
    
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

# ================= 7. 实时应用 Qdisc =================
apply_live_qdisc() {
    echo "正在实时应用 FQ 队列规则..."
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E '^(eth|en|ens|enp|eno|warp|wg|tun)' || true)
    for iface in $interfaces; do
        [ "$iface" = "lo" ] && continue
        tc qdisc del dev "$iface" root 2>/dev/null || true
        if ! tc qdisc replace dev "$iface" root fq 2>/dev/null; then
            tc qdisc replace dev "$iface" root fq_pie 2>/dev/null || true
            echo "  - $iface: 已应用 fq_pie (内核或网卡不支持 fq)"
        else
            echo "  - $iface: 已应用 fq"
        fi
    done
}

# ================= 8. Hysteria2 智能守护 =================
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
        mkdir -p /var/lib/hysteria/acme
        mkdir -p /etc/hysteria/acme
        chown -R root:root /var/lib/hysteria /etc/hysteria 2>/dev/null || true
        chmod -R 755 /var/lib/hysteria /etc/hysteria 2>/dev/null || true

        systemctl daemon-reload
        echo "  - Hysteria2 服务配置已更新 (注入 LimitNOFILE 限制解除并修复 ACME 权限)。"
    else
        echo "  - [跳过] 未在系统路径中找到 Hysteria2 主程序。"
    fi
}

# ================= 9. 自动化系统防火墙放行 (开机永久生效) =================
configure_firewall() {
    echo "----------------------------------------------------"
    echo "正在配置系统防火墙，确保端口永久放行 (80, 443, 20000-50000)..."

    local FIREWALL_MANAGED=false

    # 1. 尝试 UFW (Ubuntu/Debian 默认自带，本身就是持久化的)
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow 80/tcp >/dev/null 2>&1 || true
        ufw allow 443/tcp >/dev/null 2>&1 || true
        ufw allow 20000:50000/tcp >/dev/null 2>&1 || true
        ufw allow 20000:50000/udp >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
        echo "  - 已通过 UFW 放行端口 (规则自动永久生效)。"
        FIREWALL_MANAGED=true
    fi

    # 2. 尝试 firewalld (CentOS/Oracle Linux 默认自带，带 --permanent 就是持久化的)
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=20000-50000/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=20000-50000/udp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        echo "  - 已通过 firewalld 放行端口 (规则自动永久生效)。"
        FIREWALL_MANAGED=true
    fi

    # 3. 兜底策略：不管有没有接管，都强制写入底层 iptables 置顶放行
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport 20000:50000 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport 20000:50000 -j ACCEPT 2>/dev/null || true
        echo "  - 已将底层 iptables 规则置顶放行。"

        # 4. 如果没有被 UFW 或 Firewalld 接管，我们要强行做纯净版 iptables 的持久化保存
        if [ "$FIREWALL_MANAGED" = false ]; then
            if [ -f /etc/debian_version ]; then
                # Debian / Ubuntu 纯净环境持久化方案
                export DEBIAN_FRONTEND=noninteractive
                if ! command -v netfilter-persistent >/dev/null 2>&1; then
                    apt-get update -yqq && apt-get install -yqq iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
                fi
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                netfilter-persistent save >/dev/null 2>&1 || true
                echo "  - 检测到纯净系统，已安装 netfilter-persistent 以确保 iptables 开机永久生效。"
            elif [ -f /etc/redhat-release ]; then
                # CentOS / Oracle Linux / RHEL 纯净环境持久化方案
                mkdir -p /etc/sysconfig
                iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
                if systemctl list-unit-files | grep -q iptables.service; then
                    systemctl enable iptables >/dev/null 2>&1 || true
                fi
                echo "  - 检测到纯净系统，已保存至 /etc/sysconfig/iptables，开机永久生效。"
            fi
        fi
    fi
}

# ================= 10. 输出报告 =================
show_result() {
    echo "===================================================="
    echo "✅ VPS 智能环境监测与真实延迟优化汇总报告："
    echo " - 硬件状态: $CPU_CORES Cores / $TOTAL_MEM_MB MB ($MEM_LEVEL)"
    echo " - 本地诊断: $LATENCY_RAW ms ($LATENCY_LEVEL)"
    echo " - 拥塞算法: $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo " - 默认队列: $(sysctl -n net.core.default_qdisc)"
    echo " - 抖动与BDP: ECN=已禁用, Notsent_Lowat=$DYN_LOWAT, WinScale=$DYN_ADV_WIN."
    echo " - 防火墙态: 80/443 及 20000-50000 (TCP/UDP) 已设置开机永久放行。"
    echo "----------------------------------------------------"
    echo "⚠️ 最终提醒："
    echo "如果您使用的是 甲骨文云 (Oracle Cloud)、AWS、阿里云 等服务商，"
    echo "请【务必】前往云服务商的网页控制台，在【安全组/安全列表】中放行对应的端口，否则外网依然无法连通！"
    echo "----------------------------------------------------"
    echo "🎉 跨国全能网络优化与端口放行已完成！强烈建议 【重启系统 (reboot)】 以使配置彻底生效。"
    echo "===================================================="
}

# --- 执行流 ---
detect_hardware
detect_network_latency
prepare_env
cleanup_old_config
write_final_sysctl_config
apply_system_limits
optimize_hardware_interrupts
apply_live_qdisc
configure_hysteria_service
configure_firewall
show_result
