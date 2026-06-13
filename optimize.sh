#!/bin/bash
set -e

# ====================================================
# 脚本功能：内核极致压榨 + 硬件智能降载 + Hysteria2 终极配置 + OCI/ARM64 专属优化 + 防火墙全通
# 优化重点：UDP激进队列 + FQ起搏 + 智能动态缓冲区 + Busy_Poll 极速轮询
# 适用场景：1000M 带宽 / Hysteria2 纯 UDP 代理场景特化 / 降低延迟抖动
# 版本：V3.9 (Hysteria2 UDP/QUIC 极限压榨版)
# ====================================================

SYSCTL_FILE="/etc/sysctl.conf"
LIMITS_FILE="/etc/security/limits.conf"

echo -e "\n🚀 正在启动 VPS 极速网络全能优化脚本 V3.9 (Hysteria2 UDP/QUIC 极限压榨版)...\n"

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

# ================= 1. 手动输入真实网络延迟 =================
detect_network_latency() {
    echo "----------------------------------------------------"
    echo "为了制定最佳 BDP (带宽延迟乘积) 及 TCP 退让策略，请提供您的真实网络延迟。"
    echo "提示: 您可以通过在本地电脑运行 'ping 服务器IP' 获取，或者参考代理软件的测速结果。"
    
    # 循环要求输入，直到输入合法的数字为止
    while true; do
        read -p "请输入您本地连接至该服务器的平均延迟 (仅限输入纯数字，如 50 或 160): " LATENCY_INPUT < /dev/tty
        
        # 使用正则表达式验证输入是否为大于或等于0的纯数字
        if [[ "$LATENCY_INPUT" =~ ^[0-9]+$ ]]; then
            LATENCY_INT=$LATENCY_INPUT
            echo "  - ✅ 已接收手动输入的延迟: ${LATENCY_INT} ms"
            break
        else
            echo "  - ❌ 输入无效！请输入纯数字 (例如 150，不要带 ms 单位)。"
        fi
    done

    # 同步变量格式供后续展示
    LATENCY_RAW=$LATENCY_INT

    # TCP 策略依然保留，用于保证 SSH 稳定性和面板网页加载
    if [ "$LATENCY_INT" -gt 250 ]; then
        LATENCY_LEVEL="极端高延迟/被阻断环境 (>250ms)"
        DYN_LOWAT=262144
        DYN_ADV_WIN=1
        DYN_KEEPALIVE_PROBES=6
    elif [ "$LATENCY_INT" -gt 150 ]; then
        LATENCY_LEVEL="跨国长肥网络 (150-250ms)"
        DYN_LOWAT=262144    
        DYN_ADV_WIN=1       
        DYN_KEEPALIVE_PROBES=6
    elif [ "$LATENCY_INT" -gt 60 ]; then
        LATENCY_LEVEL="区域中等延迟 (60-150ms)"
        DYN_LOWAT=131072    
        DYN_ADV_WIN=1
        DYN_KEEPALIVE_PROBES=5
    else
        LATENCY_LEVEL="同城/优质低延迟链路 (<60ms)"
        DYN_LOWAT=16384     
        DYN_ADV_WIN=2       
        DYN_KEEPALIVE_PROBES=4
    fi

    echo "  - 最终应用延迟参数: ${LATENCY_RAW} ms [归类: $LATENCY_LEVEL]"
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
    sed -i '/# ===== VPS Optimize V3 /,/# ===== End VPS Optimize V3 /d' "$SYSCTL_FILE"
    sed -i '/# ===== VPS Optimize =====/,/# ===== End VPS Optimize =====/d' "$SYSCTL_FILE"
    
    local params=(
        "net.ipv4.tcp_congestion_control" "net.core.default_qdisc" "net.core.rmem_max" 
        "net.core.wmem_max" "net.ipv4.tcp_rmem" "net.ipv4.tcp_wmem" "net.ipv4.udp_mem"
        "net.ipv4.ipfrag_high_thresh" "net.ipv4.tcp_notsent_lowat" "net.ipv4.tcp_fastopen"
        "net.netfilter.nf_conntrack_max" "net.ipv4.tcp_mtu_probing" "net.ipv4.tcp_ecn"
        "net.ipv4.tcp_adv_win_scale" "net.core.busy_read" "net.core.busy_poll"
    )
    for param in "${params[@]}"; do
        sed -i "/^\s*${param}\s*=/d" "$SYSCTL_FILE"
    done
    echo "  - 已完成冲突项清理。"
}

# ================= 4. 写入极限优化网络参数 =================
write_final_sysctl_config() {
    echo "正在根据硬件配置写入系统内核参数 (Hysteria2/QUIC 专项深度优化)..."

    cat >> "$SYSCTL_FILE" <<EOF

# ===== VPS Optimize V3.9 (Hysteria2 UDP/QUIC 版) =====
# --- 拥塞控制与队列 (BBR 保底 TCP，FQ 起搏 UDP) ---
# [HY2 核心机制]: QUIC 协议极度依赖 FQ (Fair Queueing) 来进行发包起搏(Pacing)，能有效防止 Brutal 爆发发包压垮路由
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- UDP 专属缓冲区与内存极限优化 ---
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.core.rmem_default = $RMEM_DEFAULT
net.core.wmem_default = $WMEM_DEFAULT
net.ipv4.tcp_rmem = 4096 87380 $RMEM_MAX
net.ipv4.tcp_wmem = 4096 65536 $WMEM_MAX

# [HY2 核心机制]: 大幅提升 UDP Socket 的起始分配内存，防止大流量下内核频繁介入申请内存导致延迟突增
net.ipv4.udp_rmem_min = 32768
net.ipv4.udp_wmem_min = 32768
net.ipv4.udp_mem = $UDP_MEM
net.core.optmem_max = 262144

# --- Socket 极速轮询 (金融级低延迟特性) ---
# [HY2 核心机制]: 让 CPU 主动轮询网卡拉取 UDP 包，减少硬中断等待上下文切换的时间。会略微增加 CPU 负载，但可显著消除 Hysteria2 的微小抖动卡顿
net.core.busy_read = 50
net.core.busy_poll = 50

# --- UDP 分片重组深度优化 ---
net.ipv4.ipfrag_high_thresh = $RMEM_MAX
net.ipv4.ipfrag_low_thresh = $FRAG_LOW
net.ipv4.ipfrag_time = 60

# --- 基于端到端真实延迟感知的防抖动 TCP 精修 (为 SSH 和面板保驾护航) ---
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = $DYN_ADV_WIN
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = $DYN_LOWAT
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 2
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_timestamps = 1

# --- 连接追踪、并发与极速回收集 ---
net.netfilter.nf_conntrack_max = $CONNTRACK_MAX
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.core.somaxconn = 65535
# [HY2 核心机制]: 提升网卡收包处理积压队列上限，承接 Brutal 算法的突发大流量 UDP 包
net.core.netdev_max_backlog = 100000
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
# ===== End VPS Optimize V3.9 =====
EOF

    sysctl --system >/dev/null 2>&1
    echo "  - 内核参数应用成功 (Hysteria2 特化规则已注入)。"
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

# ================= 7. 实时应用 Qdisc 队列与网卡 TX 扩容 =================
apply_live_qdisc() {
    echo "正在实时应用 FQ 队列规则及 Hysteria2 专项发送队列扩容..."
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E '^(eth|en|ens|enp|eno|warp|wg|tun)' || true)
    for iface in $interfaces; do
        [ "$iface" = "lo" ] && continue
        
        # [HY2 核心机制]: Linux 网卡默认 txqueuelen 一般为 1000。
        # Brutal 算法在启动瞬间会发射巨大数量包，1000 的队列会瞬间溢出，导致内核强制丢包断流。扩容到 10000 极度关键！
        ip link set dev "$iface" txqueuelen 10000 2>/dev/null || true
        
        tc qdisc del dev "$iface" root 2>/dev/null || true
        if ! tc qdisc replace dev "$iface" root fq 2>/dev/null; then
            tc qdisc replace dev "$iface" root fq_pie 2>/dev/null || true
            echo "  - $iface: 已应用 fq_pie (网卡不支持 fq)，已扩容 txqueuelen 至 10000"
        else
            echo "  - $iface: 已应用 fq 并扩容 txqueuelen 至 10000 (QUIC 起搏最佳组合)"
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
# 开启内核级别的特权，允许 Hysteria2 进程锁住内存避免 SWAP 换出
LimitMEMLOCK=infinity
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
        echo "  - Hysteria2 服务配置已更新 (注入无上限内存锁及 LimitNOFILE 限制解除)。"
    else
        echo "  - [跳过] 未在系统路径中找到 Hysteria2 主程序。"
    fi
}

# ================= 9. 自动化系统防火墙放行 (开机永久生效) =================
configure_firewall() {
    echo "----------------------------------------------------"
    echo "正在配置系统防火墙，确保端口永久放行 (80, 443, 20000-50000)..."

    local FIREWALL_MANAGED=false

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow 80/tcp >/dev/null 2>&1 || true
        ufw allow 443/tcp >/dev/null 2>&1 || true
        ufw allow 443/udp >/dev/null 2>&1 || true
        ufw allow 20000:50000/tcp >/dev/null 2>&1 || true
        ufw allow 20000:50000/udp >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
        echo "  - 已通过 UFW 放行端口 (规则自动永久生效)。"
        FIREWALL_MANAGED=true
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=443/udp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=20000-50000/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=20000-50000/udp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        echo "  - 已通过 firewalld 放行端口 (规则自动永久生效)。"
        FIREWALL_MANAGED=true
    fi

    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport 20000:50000 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport 20000:50000 -j ACCEPT 2>/dev/null || true
        echo "  - 已将底层 iptables 规则置顶放行。"

        if [ "$FIREWALL_MANAGED" = false ]; then
            if [ -f /etc/debian_version ]; then
                export DEBIAN_FRONTEND=noninteractive
                if ! command -v netfilter-persistent >/dev/null 2>&1; then
                    apt-get update -yqq && apt-get install -yqq iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
                fi
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                netfilter-persistent save >/dev/null 2>&1 || true
                echo "  - 检测到纯净系统，已安装 netfilter-persistent 以确保 iptables 开机永久生效。"
            elif [ -f /etc/redhat-release ]; then
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
    echo "✅ VPS 智能环境监测与 Hysteria2 专项优化汇总："
    echo " - 硬件状态: $CPU_CORES Cores / $TOTAL_MEM_MB MB ($MEM_LEVEL)"
    echo " - UDP 特化: 队列扩容(txqueuelen=10000), 内存提升, BusyPoll极速轮询(启用)"
    echo " - TCP 保底: $LATENCY_RAW ms BDP 规则 ($LATENCY_LEVEL)"
    echo " - 拥塞与队列: $(sysctl -n net.ipv4.tcp_congestion_control) + $(sysctl -n net.core.default_qdisc)"
    echo " - 防火墙态: 80/443 及 20000-50000 (TCP/UDP) 已设置开机永久放行。"
    echo "----------------------------------------------------"
    echo "⚠️ 最终提醒："
    echo "如果您使用的是 甲骨文云 (Oracle Cloud)、AWS、阿里云 等服务商，"
    echo "请【务必】前往云服务商的网页控制台，在【安全组/安全列表】中放行对应的端口，否则外网依然无法连通！"
    echo "----------------------------------------------------"
    echo "🎉 Hysteria2 深度特化版优化已完成！强烈建议 【重启系统 (reboot)】 以使配置彻底生效。"
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
