#!/bin/bash
set -e

# ====================================================
# 脚本功能：内核极致压榨 + 硬件智能降载 + Hysteria2 终极配置 + OCI/ARM64 专属优化 + 防火墙全通
# 优化重点：UDP激进队列 + FQ精细起搏 + 智能动态缓冲区 + Busy_Poll 极速轮询
# 适用场景：1000M 带宽 / Hysteria2 纯 UDP 代理场景特化 / 降低延迟抖动
# 版本：V5.0 (海外高延迟场景极限专项优化版)
# V5.0 升级内容：
#   1. 海外高延迟场景专项优化 — 根据延迟分级提供更激进的 QUIC 窗口和缓冲区参数。
#   2. UDP 连接跟踪超时大幅提升 — 防止海外 NAT 穿透断连 (动态适配至最高 300s/600s)。
#   3. fq qdisc maxrate 动态适配 — 针对跨国链路精细化限流起搏，防止突发包堵死路由。
#   4. 新增 ECN 检测逻辑 — 针对海外链路 ECN 不可靠进行动态开关。
#   5. GSO/GRO offload 专项优化 — 开启 rx-udp-gro-forwarding，减少高频小包 CPU 开销。
#   6. 强开 MTU Probing (值为2) — 彻底防止海外链路 MTU 黑洞。
#   7. systemd 服务提权 — 新增 Nice 与 IOSchedulingClass，保证 Hysteria2 调度优先级。
# ====================================================

SYSCTL_FILE="/etc/sysctl.conf"
LIMITS_FILE="/etc/security/limits.conf"

echo -e "\n🚀 正在启动 VPS 极速网络全能优化脚本 V5.0 (海外高延迟场景极限专项优化版)...\n"

# ================= 0. 硬件环境自动侦测 =================
detect_hardware() {
    echo "正在侦测硬件配置以进行动态适应..."
    TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc)
    ARCH=$(uname -m)

    # 内存分级逻辑：保障基础 Socket 缓冲区上限
    if [ "$TOTAL_MEM_MB" -lt 1024 ]; then
        MEM_LEVEL="低配 (< 1GB)"
        RMEM_MAX=33554432      # 32MB
        WMEM_MAX=33554432
        UDP_MEM="65536 131072 262144"
        CONNTRACK_MAX=262144
    elif [ "$TOTAL_MEM_MB" -lt 4096 ]; then
        MEM_LEVEL="中配 (1GB - 4GB)"
        RMEM_MAX=67108864      # 64MB
        WMEM_MAX=67108864
        UDP_MEM="131072 262144 524288"
        CONNTRACK_MAX=786432   # V5.0: 中配以上大幅提升以承载更长的 UDP 超时
    else
        MEM_LEVEL="高配 (>= 4GB)"
        RMEM_MAX=134217728     # 128MB
        WMEM_MAX=134217728
        UDP_MEM="262144 524288 786432"
        CONNTRACK_MAX=2097152  # V5.0: 高配提升至 200W+
    fi

    RMEM_DEFAULT=$(( RMEM_MAX / 4 ))
    WMEM_DEFAULT=$(( WMEM_MAX / 4 ))
    FRAG_LOW=$(( RMEM_MAX * 3 / 4 ))

    echo "  - 架构: $ARCH"
    echo "  - 核心数: $CPU_CORES Core(s)"
    echo "  - 总内存: $TOTAL_MEM_MB MB ($MEM_LEVEL)"
    echo "  - 基础最大缓冲区分配: $(( RMEM_MAX / 1024 / 1024 )) MB"
}

# ================= 1. 手动输入真实网络延迟并动态分配参数 (V5.0 核心逻辑) =================
detect_network_latency() {
    echo "----------------------------------------------------"
    echo "为了制定最佳 BDP 及 V5.0 的 QUIC/FQ/NAT 专项策略，请提供您的真实网络延迟。"
    echo "提示: 您可以通过在本地电脑运行 'ping 服务器IP' 获取，或者参考代理软件的测速结果。"

    while true; do
        read -p "请输入您本地连接至该服务器的平均延迟 (仅限输入纯数字，如 50 或 160): " LATENCY_INPUT < /dev/tty
        if [[ "$LATENCY_INPUT" =~ ^[0-9]+$ ]]; then
            LATENCY_INT=$LATENCY_INPUT
            echo "  - ✅ 已接收手动输入的延迟: ${LATENCY_INT} ms"
            break
        else
            echo "  - ❌ 输入无效！请输入纯数字 (例如 150，不要带 ms 单位)。"
        fi
    done

    LATENCY_RAW=$LATENCY_INT

    # [V5.0 新增]: 根据延迟档位，全面定制 ECN、UDP超时、FQ maxrate 和 QUIC 窗口
    if [ "$LATENCY_INT" -gt 250 ]; then
        LATENCY_LEVEL="极端高延迟/被阻断环境 (>250ms)"
        DYN_LOWAT=262144
        DYN_ADV_WIN=1
        DYN_KEEPALIVE_PROBES=6
        
        # V5.0 动态策略
        FQ_MAXRATE="500mbit"     # 强力 Pacing，防止突发包压垮脆弱链路
        ECN_VAL=0                # 海外跨国 ECN 极不可靠，强制关闭
        UDP_TIMEOUT=300          # 极长超时，应对复杂 NAT 和高丢包
        UDP_STREAM=600
        
        # 激进的 QUIC 窗口适配 (充分利用高 BDP)
        HY2_INIT_STREAM=$(( RMEM_MAX / 4 ))
        HY2_MAX_STREAM=$(( RMEM_MAX / 2 ))
        HY2_INIT_CONN=$(( RMEM_MAX / 2 ))
        HY2_MAX_CONN=$(( RMEM_MAX ))

    elif [ "$LATENCY_INT" -gt 150 ]; then
        LATENCY_LEVEL="跨国长肥网络 (150-250ms)"
        DYN_LOWAT=262144
        DYN_ADV_WIN=1
        DYN_KEEPALIVE_PROBES=6
        
        FQ_MAXRATE="1gbit"
        ECN_VAL=0
        UDP_TIMEOUT=150
        UDP_STREAM=300
        
        HY2_INIT_STREAM=$(( RMEM_MAX / 5 ))
        HY2_MAX_STREAM=$(( RMEM_MAX / 2 ))
        HY2_INIT_CONN=$(( RMEM_MAX / 2 ))
        HY2_MAX_CONN=$(( RMEM_MAX * 3 / 4 ))

    elif [ "$LATENCY_INT" -gt 60 ]; then
        LATENCY_LEVEL="区域中等延迟 (60-150ms)"
        DYN_LOWAT=131072
        DYN_ADV_WIN=1
        DYN_KEEPALIVE_PROBES=5
        
        FQ_MAXRATE="2gbit"
        ECN_VAL=0                # 60ms 以上跨区依然建议关闭 ECN
        UDP_TIMEOUT=90
        UDP_STREAM=180
        
        HY2_INIT_STREAM=$(( RMEM_MAX / 6 ))
        HY2_MAX_STREAM=$(( RMEM_MAX / 3 ))
        HY2_INIT_CONN=$(( RMEM_MAX / 3 ))
        HY2_MAX_CONN=$(( RMEM_MAX / 2 ))

    else
        LATENCY_LEVEL="同城/优质低延迟链路 (<60ms)"
        DYN_LOWAT=16384
        DYN_ADV_WIN=2
        DYN_KEEPALIVE_PROBES=4
        
        FQ_MAXRATE="10gbit"      # 局域网/同城几乎不限速
        ECN_VAL=1                # 优质链路开启 ECN 可获得微弱优势
        UDP_TIMEOUT=60
        UDP_STREAM=120
        
        # 低延迟不需要过大的窗口，避免无谓的内存浪费
        HY2_INIT_STREAM=$(( RMEM_MAX / 8 ))
        HY2_MAX_STREAM=$(( RMEM_MAX / 4 ))
        HY2_INIT_CONN=$(( RMEM_MAX / 4 ))
        HY2_MAX_CONN=$(( RMEM_MAX / 3 ))
    fi

    echo "  - 最终归类: $LATENCY_LEVEL"
    echo "  - TCP 退让策略分配: Lowat=${DYN_LOWAT}, WinScale=${DYN_ADV_WIN}"
    echo "  - V5.0 海外专项策略分配: FQ Maxrate=${FQ_MAXRATE}, ECN=${ECN_VAL}, NAT超时=${UDP_TIMEOUT}s"
    echo "----------------------------------------------------"
}

# ================= 2. 基础环境与模块准备 =================
prepare_env() {
    echo "正在加载必要的内核模块 (BBR, Conntrack)..."
    modprobe tcp_bbr 2>/dev/null || true
    modprobe nf_conntrack 2>/dev/null || true

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
    rm -f /etc/sysctl.d/99-vps-optimize.conf /etc/sysctl.d/99-bbr.conf \
          /etc/sysctl.d/98-bbr.conf /etc/sysctl.d/99-netopt.conf

    cp -a "$SYSCTL_FILE" "${SYSCTL_FILE}.bak.$(date +%s)"
    sed -i '/# ===== VPS Optimize V2 =====/,/# ===== End VPS Optimize V2 =====/d' "$SYSCTL_FILE"
    sed -i '/# ===== VPS Optimize V3 /,/# ===== End VPS Optimize V3 /d' "$SYSCTL_FILE"
    sed -i '/# ===== VPS Optimize V4 /,/# ===== End VPS Optimize V4 /d' "$SYSCTL_FILE"
    sed -i '/# ===== VPS Optimize V5 /,/# ===== End VPS Optimize V5 /d' "$SYSCTL_FILE"
    sed -i '/# ===== VPS Optimize =====/,/# ===== End VPS Optimize =====/d' "$SYSCTL_FILE"

    local params=(
        "net.ipv4.tcp_congestion_control" "net.core.default_qdisc"
        "net.core.rmem_max" "net.core.wmem_max"
        "net.core.rmem_default" "net.core.wmem_default"
        "net.ipv4.tcp_rmem" "net.ipv4.tcp_wmem"
        "net.ipv4.udp_mem" "net.ipv4.udp_rmem_min" "net.ipv4.udp_wmem_min"
        "net.core.optmem_max"
        "net.ipv4.ipfrag_high_thresh" "net.ipv4.ipfrag_low_thresh" "net.ipv4.ipfrag_time"
        "net.ipv4.tcp_notsent_lowat" "net.ipv4.tcp_fastopen"
        "net.ipv4.tcp_window_scaling" "net.ipv4.tcp_adv_win_scale"
        "net.ipv4.tcp_slow_start_after_idle" "net.ipv4.tcp_ecn"
        "net.ipv4.tcp_frto" "net.ipv4.tcp_sack" "net.ipv4.tcp_dsack"
        "net.ipv4.tcp_fack" "net.ipv4.tcp_timestamps"
        "net.netfilter.nf_conntrack_max" "net.netfilter.nf_conntrack_tcp_timeout_established"
        "net.netfilter.nf_conntrack_udp_timeout" "net.netfilter.nf_conntrack_udp_timeout_stream"
        "net.core.somaxconn" "net.core.netdev_max_backlog"
        "net.core.netdev_budget" "net.core.netdev_budget_usecs"
        "net.ipv4.tcp_max_syn_backlog" "net.ipv4.tcp_max_tw_buckets"
        "net.ipv4.tcp_tw_reuse" "net.ipv4.tcp_fin_timeout"
        "net.ipv4.tcp_retries2" "net.ipv4.tcp_keepalive_time"
        "net.ipv4.tcp_keepalive_probes" "net.ipv4.tcp_keepalive_intvl"
        "net.ipv4.ip_no_pmtu_disc" "net.ipv4.tcp_mtu_probing" "net.ipv4.tcp_base_mss"
        "net.core.busy_read" "net.core.busy_poll"
        "net.ipv4.ip_local_port_range"
    )
    for param in "${params[@]}"; do
        sed -i "/^\s*${param}\s*=/d" "$SYSCTL_FILE"
    done
    echo "  - 已完成冲突项清理。"
}

# ================= 4. 写入极限优化网络参数 =================
write_final_sysctl_config() {
    echo "正在根据硬件配置写入系统内核参数 (V5.0 海外高延迟专项优化)..."

    cat >> "$SYSCTL_FILE" <<EOF

# ===== VPS Optimize V5.0 (海外高延迟场景极限专项优化版) =====

# --- 拥塞控制与队列 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Socket 收发缓冲区 ---
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.core.rmem_default = $RMEM_DEFAULT
net.core.wmem_default = $WMEM_DEFAULT
net.ipv4.tcp_rmem = 4096 87380 $RMEM_MAX
net.ipv4.tcp_wmem = 4096 65536 $WMEM_MAX

# --- UDP 专属缓冲区与内存优化 ---
net.ipv4.udp_rmem_min = 32768
net.ipv4.udp_wmem_min = 32768
net.ipv4.udp_mem = $UDP_MEM
net.core.optmem_max = 262144

# --- Socket 极速轮询 ---
net.core.busy_read = 50
net.core.busy_poll = 50

# --- UDP 分片重组 ---
net.ipv4.ipfrag_high_thresh = $RMEM_MAX
net.ipv4.ipfrag_low_thresh = $FRAG_LOW
net.ipv4.ipfrag_time = 60

# --- TCP 参数精修 ---
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = $DYN_ADV_WIN
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = $DYN_LOWAT
# [V5.0 新增]: 根据网络质量智能启停 ECN
net.ipv4.tcp_ecn = $ECN_VAL
net.ipv4.tcp_frto = 2
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_timestamps = 1

# --- 连接追踪与 NAT 保活 (V5.0 海外优化重点) ---
net.netfilter.nf_conntrack_max = $CONNTRACK_MAX
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
# [V5.0 新增]: 动态适配的超长 UDP 追踪时间，穿透海外严苛 NAT
net.netfilter.nf_conntrack_udp_timeout = $UDP_TIMEOUT
net.netfilter.nf_conntrack_udp_timeout_stream = $UDP_STREAM

# --- 并发与连接队列 ---
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 100000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 25

# --- 本地端口范围扩展 ---
net.ipv4.ip_local_port_range = 1024 65535

# --- NAT 幽灵断线保活修复 ---
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = $DYN_KEEPALIVE_PROBES
net.ipv4.tcp_keepalive_intvl = 15

# --- 路径 MTU 与 Fast Open (V5.0 海外优化重点) ---
net.ipv4.ip_no_pmtu_disc = 0
# [V5.0 新增]: 强制主动探测 MTU 黑洞 (2)，防止海外路由封锁 ICMP 导致断流
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_fastopen = 1

# ===== End VPS Optimize V5.0 =====
EOF

    sysctl --system >/dev/null 2>&1
    echo "  - 内核参数应用成功 (V5.0 动态规则已注入)。"
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

# ================= 6. 网卡硬件智能调优 (V5.0 GSO/GRO 专项优化) =================
optimize_hardware_interrupts() {
    echo "正在执行硬件中断调优与 UDP 卸载 (Offload) 优化..."

    if [ "$CPU_CORES" -gt 1 ]; then
        if ! command -v irqbalance >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y irqbalance >/dev/null 2>&1 || true
        fi
        systemctl enable irqbalance 2>/dev/null || true
        systemctl start irqbalance 2>/dev/null || true
    else
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
        
        # [V5.0 新增]: 强化 UDP GRO/GSO 处理，大幅降低 Hysteria2 高频小包在系统内核态造成的 CPU 开销
        ethtool -K "$iface" gso on tso on gro on 2>/dev/null || true
        # 针对较新内核尝试开启高级 UDP 卸载
        ethtool -K "$iface" rx-udp-gro-forwarding on 2>/dev/null || true
        ethtool -K "$iface" rx-gro-list on 2>/dev/null || true
        echo "  - $iface: GRO/GSO 与高级 UDP Offload 特性已激活。"
    done
}

# ================= 7. 实时应用 Qdisc 队列与网卡 TX 扩容 =================
apply_live_qdisc() {
    echo "正在实时应用 FQ 队列规则及 Hysteria2 专项发送队列扩容..."
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' \
        | grep -E '^(eth|en|ens|enp|eno|warp|wg|tun)' || true)

    for iface in $interfaces; do
        [ "$iface" = "lo" ] && continue

        ip link set dev "$iface" txqueuelen 10000 2>/dev/null || true
        tc qdisc del dev "$iface" root 2>/dev/null || true

        # [V5.0 新增]: 采用动态 maxrate 限制流量发送速率 (Pacing)，避免突发包在长肥网络中引发路由拥塞丢包
        if ! tc qdisc replace dev "$iface" root fq flow_limit 400 buckets 65536 maxrate "$FQ_MAXRATE" 2>/dev/null; then
            if ! tc qdisc replace dev "$iface" root fq 2>/dev/null; then
                tc qdisc replace dev "$iface" root fq_pie 2>/dev/null || true
                echo "  - $iface: 已应用 fq_pie (网卡不支持 fq)，txqueuelen 已扩容至 10000"
            else
                echo "  - $iface: 已应用 fq (基础参数)，txqueuelen 已扩容至 10000"
            fi
        else
            echo "  - $iface: 已应用 fq (flow=400, buckets=64k, maxrate=$FQ_MAXRATE) + txqueuelen=10000 [V5.0 最优]"
        fi
    done
}

# ================= 8. Hysteria2 智能守护 (V5.0 系统提权) =================
configure_hysteria_service() {
    echo "----------------------------------------------------"
    HY_BIN=$(command -v hysteria 2>/dev/null || echo "/usr/local/bin/hysteria")

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

        if [ "$CPU_CORES" -gt 1 ]; then
            CPU_SCHED_LINES="CPUSchedulingPolicy=fifo
CPUSchedulingPriority=50"
            echo "  - 多核环境: 已为 Hysteria2 开启实时调度 (fifo priority=50)"
        else
            CPU_SCHED_LINES="# 单核环境: 跳过实时调度，避免影响系统稳定性"
            echo "  - 单核环境: 跳过实时调度配置"
        fi

        # [V5.0 新增]: IO 调度优化与 Nice 提权，防止代理进程被系统降级挂起
        cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria Server Service ${DESC_SUFFIX} (V5.0 Optimized)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
${WAIT_LOGIC}
ExecStart=${HY_BIN} server --config /etc/hysteria/config.yaml
WorkingDirectory=/var/lib/hysteria
User=root

# 基础资源限制解除
LimitMEMLOCK=infinity
LimitNOFILE=1048576

# V5.0 专项提权：确保高并发下的极速响应
Nice=-10
IOSchedulingClass=realtime
IOSchedulingPriority=4
${CPU_SCHED_LINES}

Environment=HYSTERIA_LOG_LEVEL=info
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF
        mkdir -p /var/lib/hysteria/acme /etc/hysteria/acme
        chown -R root:root /var/lib/hysteria /etc/hysteria 2>/dev/null || true
        chmod -R 755 /var/lib/hysteria /etc/hysteria 2>/dev/null || true

        systemctl daemon-reload
        echo "  - Hysteria2 服务配置已更新 (已应用 V5.0 Nice/IO提权规则)。"
    else
        echo "  - [跳过] 未在系统路径中找到 Hysteria2 主程序。"
    fi
}

# ================= 9. 自动化系统防火墙放行 =================
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
                echo "  - 检测到纯净系统，已安装 netfilter-persistent 确保 iptables 开机永久生效。"
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

# ================= 10. 输出报告 + Hysteria2 config.yaml 推荐参数 =================
show_result() {
    echo ""
    echo "===================================================="
    echo "✅ VPS 智能环境监测与海外高延迟 V5.0 专项优化汇总："
    echo " - 硬件状态   : $CPU_CORES Cores / $TOTAL_MEM_MB MB ($MEM_LEVEL)"
    echo " - 链路状态   : ${LATENCY_RAW} ms ($LATENCY_LEVEL)"
    echo " - UDP Offload: GRO/GSO 高级分片卸载已针对小包优化"
    echo " - FQ 动态流控: maxrate = ${FQ_MAXRATE} (缓解长肥网络瞬时突发丢包)"
    echo " - ECN 状态   : $( [ "$ECN_VAL" -eq 1 ] && echo '开启 (低延迟优选)' || echo '强制关闭 (规避海外黑洞)' )"
    echo " - MTU 保护   : tcp_mtu_probing = 2 (彻底防护断流)"
    echo " - NAT 保活   : UDP timeout=${UDP_TIMEOUT}s / stream=${UDP_STREAM}s (极致保活)"
    echo " - 进程守护   : systemd 已配置 Nice=-10 & IO 实时提权"
    echo "----------------------------------------------------"

    echo ""
    echo "📋 【核心】Hysteria2 config.yaml V5.0 动态推荐 QUIC 参数："
    echo "   (系统已根据您的 [${LATENCY_RAW}ms 延迟] 与 [${TOTAL_MEM_MB}MB 内存] 自动调校了以下最优窗口)"
    echo ""
    echo "   quic:"
    echo "     initStreamReceiveWindow: $HY2_INIT_STREAM"
    echo "     maxStreamReceiveWindow:  $HY2_MAX_STREAM"
    echo "     initConnReceiveWindow:   $HY2_INIT_CONN"
    echo "     maxConnReceiveWindow:    $HY2_MAX_CONN"
    echo ""
    echo "   建议将以上参数填入 /etc/hysteria/config.yaml，并在客户端同步配置！"
    echo "----------------------------------------------------"
    echo "⚠️  最终提醒："
    echo "如果您使用的是 甲骨文云 (OCI)、AWS、阿里云 等服务商，"
    echo "请【务必】前往云控制台的【安全组/安全列表】放行对应端口，否则外网依然无法连通！"
    echo "----------------------------------------------------"
    echo "🎉 V5.0 优化脚本执行完毕！请务必执行 【reboot】 重启系统以激活内核高级网络栈！"
    echo "===================================================="
}

# =================== 执行流 ===================
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
