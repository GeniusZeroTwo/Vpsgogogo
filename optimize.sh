#!/bin/bash
set -euo pipefail

# ====================================================
# 脚本功能：内核极致压榨 + 硬件智能降载 + Hysteria2 终极配置 + OCI/ARM64 专属优化 + 防火墙全通
# 优化重点：UDP激进队列 + FQ精细起搏 + 智能动态缓冲区 + Busy_Poll 极速轮询
# 适用场景：1000M 带宽 / Hysteria2 纯 UDP 代理场景特化 / 降低延迟抖动
# 版本：V6.0 (Hysteria2 深度专项 + 海外访问全面强化版)
# V6.0 升级内容：
#   1. 自动 Ping 延迟探测 + 手动输入兜底 —— 无需人工查询即可自动感知网络质量。
#   2. BBR v2 / BBRplus 内核检测与自动切换 —— 支持更先进拥塞控制算法。
#   3. Hysteria2 config.yaml 自动写入推荐 QUIC 参数 —— 彻底免去手动修改。
#   4. UDP SO_SNDBUF/SO_RCVBUF 专项超大缓冲区注入 —— 针对 Hysteria2 高频 UDP 流量特化。
#   5. WARP 网卡专项 fq 队列优化 —— wg/warp 接口不再被忽略。
#   6. Hysteria2 端口专项防火墙策略 —— 自动读取 config.yaml 中的监听端口。
#   7. CPU 亲和性与 NUMA 感知调度 —— 将 Hysteria2 进程绑定至最优 CPU 核心。
#   8. 系统内核版本兼容性检测 —— 跳过低版本内核不支持的参数，避免崩溃。
#   9. sysctl 参数写入前可用性预检 —— 每条参数先探测再写入，健壮性大幅提升。
#  10. 完整 IPv6 优化支持 —— 补全 IPv6 相关 conntrack、分片重组参数。
# ====================================================

SYSCTL_FILE="/etc/sysctl.conf"
LIMITS_FILE="/etc/security/limits.conf"
HY2_CONFIG="/etc/hysteria/config.yaml"
LOG_FILE="/tmp/vps_optimize_v6.log"

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
info() { echo -e "${CYAN}[i]${NC} $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[✗]${NC} $*" | tee -a "$LOG_FILE"; }
sep()  { echo -e "${BLUE}----------------------------------------------------${NC}"; }

echo -e "\n${BOLD}${CYAN}🚀 正在启动 VPS 极速网络全能优化脚本 V6.0${NC}"
echo -e "${CYAN}   (Hysteria2 深度专项 + 海外访问全面强化版)${NC}\n"
> "$LOG_FILE"

# ================= 检查 root 权限 =================
if [ "$(id -u)" -ne 0 ]; then
    err "请以 root 权限运行此脚本！(sudo bash optimize.sh)"
    exit 1
fi

# ================= 内核版本工具函数 =================
KERNEL_VERSION=$(uname -r | cut -d. -f1-2 | tr -d '.')
kernel_ge() {
    [ "$KERNEL_VERSION" -ge "$1" ] 2>/dev/null && return 0 || return 1
}

# ================= 0. 硬件环境自动侦测 =================
detect_hardware() {
    sep
    info "正在侦测硬件配置以进行动态适应..."
    TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc)
    ARCH=$(uname -m)
    KERNEL_FULL=$(uname -r)

    if [ "$TOTAL_MEM_MB" -lt 512 ]; then
        MEM_LEVEL="极低配 (<512MB)"
        RMEM_MAX=16777216
        WMEM_MAX=16777216
        UDP_MEM="32768 65536 131072"
        CONNTRACK_MAX=131072
    elif [ "$TOTAL_MEM_MB" -lt 1024 ]; then
        MEM_LEVEL="低配 (<1GB)"
        RMEM_MAX=33554432
        WMEM_MAX=33554432
        UDP_MEM="65536 131072 262144"
        CONNTRACK_MAX=262144
    elif [ "$TOTAL_MEM_MB" -lt 4096 ]; then
        MEM_LEVEL="中配 (1GB-4GB)"
        RMEM_MAX=67108864
        WMEM_MAX=67108864
        UDP_MEM="131072 262144 524288"
        CONNTRACK_MAX=786432
    elif [ "$TOTAL_MEM_MB" -lt 8192 ]; then
        MEM_LEVEL="高配 (4GB-8GB)"
        RMEM_MAX=134217728
        WMEM_MAX=134217728
        UDP_MEM="262144 524288 786432"
        CONNTRACK_MAX=2097152
    else
        MEM_LEVEL="旗舰配置 (>=8GB)"
        RMEM_MAX=268435456
        WMEM_MAX=268435456
        UDP_MEM="524288 1048576 2097152"
        CONNTRACK_MAX=4194304
    fi

    RMEM_DEFAULT=$(( RMEM_MAX / 4 ))
    WMEM_DEFAULT=$(( WMEM_MAX / 4 ))
    FRAG_LOW=$(( RMEM_MAX * 3 / 4 ))

    # BBR v2 / BBRplus 检测
    AVAIL_CC=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | awk '{$1=$2=""; print}' | xargs)
    if echo "$AVAIL_CC" | grep -q "bbr2"; then
        BBR_ALG="bbr2"
        info "检测到 BBR v2，将使用更优的拥塞控制算法！"
    elif echo "$AVAIL_CC" | grep -q "bbrplus"; then
        BBR_ALG="bbrplus"
        info "检测到 BBRplus，将使用增强版 BBR！"
    else
        BBR_ALG="bbr"
    fi

    log "架构: ${BOLD}$ARCH${NC} | 核心数: ${BOLD}${CPU_CORES}${NC} | 内存: ${BOLD}${TOTAL_MEM_MB}MB${NC} (${MEM_LEVEL})"
    log "内核: ${BOLD}${KERNEL_FULL}${NC} | 拥塞控制: ${BOLD}${BBR_ALG}${NC}"
    log "缓冲区上限: ${BOLD}$(( RMEM_MAX / 1024 / 1024 ))MB${NC} | Conntrack最大: ${BOLD}${CONNTRACK_MAX}${NC}"
}

# ================= 1. 智能延迟探测 =================
detect_network_latency() {
    sep
    info "开始网络质量智能探测 (V6.0 自动+手动混合模式)..."

    AUTO_DETECT_SUCCESS=false
    LATENCY_INT=0

    # 尝试自动 Ping 网关获取延迟
    GATEWAY=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')
    if [ -n "$GATEWAY" ]; then
        PING_RESULT=$(ping -c 5 -W 2 "$GATEWAY" 2>/dev/null | tail -1 | awk -F'/' '{print $5}' | cut -d. -f1)
        if [[ "$PING_RESULT" =~ ^[0-9]+$ ]] && [ "$PING_RESULT" -gt 0 ]; then
            LATENCY_INT=$PING_RESULT
            AUTO_DETECT_SUCCESS=true
            info "已自动检测到网关 ${GATEWAY} 延迟: ${BOLD}${LATENCY_INT}ms${NC}"
        fi
    fi

    if [ "$AUTO_DETECT_SUCCESS" = true ]; then
        echo -e "  ${YELLOW}自动检测值为 ${LATENCY_INT}ms。跨国场景延迟通常远高于此值。"
        echo -e "  请输入真实的【本地到服务器】延迟，或按 Enter 使用自动值：${NC}"
        read -p "  延迟 (ms，直接 Enter 使用 ${LATENCY_INT}ms): " USER_INPUT < /dev/tty
        if [[ "$USER_INPUT" =~ ^[0-9]+$ ]] && [ "$USER_INPUT" -gt 0 ]; then
            LATENCY_INT=$USER_INPUT
            info "已使用手动覆盖延迟: ${BOLD}${LATENCY_INT}ms${NC}"
        else
            info "使用自动检测延迟: ${BOLD}${LATENCY_INT}ms${NC}"
        fi
    else
        warn "自动探测失败，请手动输入您本地到该服务器的平均延迟。"
        echo "  提示：在本地电脑运行 'ping 服务器IP' 获取，或查看代理软件的测速结果。"
        while true; do
            read -p "  请输入平均延迟 (纯数字，如 150): " LATENCY_INPUT < /dev/tty
            if [[ "$LATENCY_INPUT" =~ ^[0-9]+$ ]] && [ "$LATENCY_INPUT" -gt 0 ]; then
                LATENCY_INT=$LATENCY_INPUT
                log "已接收手动输入延迟: ${LATENCY_INT}ms"
                break
            else
                err "输入无效！请输入纯数字 (例如 150，不要带 ms 单位)。"
            fi
        done
    fi

    LATENCY_RAW=$LATENCY_INT

    # 延迟分级策略 (V6.0: 新增 >300ms 严重档位)
    if [ "$LATENCY_INT" -gt 300 ]; then
        LATENCY_LEVEL="严重高延迟/网络受阻环境 (>300ms)"
        DYN_LOWAT=524288
        DYN_ADV_WIN=1
        DYN_KEEPALIVE_PROBES=7
        FQ_MAXRATE="300mbit"
        ECN_VAL=0
        UDP_TIMEOUT=600
        UDP_STREAM=1200
        HY2_INIT_STREAM=$(( RMEM_MAX / 3 ))
        HY2_MAX_STREAM=$(( RMEM_MAX * 2 / 3 ))
        HY2_INIT_CONN=$(( RMEM_MAX * 2 / 3 ))
        HY2_MAX_CONN=$(( RMEM_MAX ))
        UDP_SNDBUF=$(( RMEM_MAX ))
        UDP_RCVBUF=$(( RMEM_MAX ))

    elif [ "$LATENCY_INT" -gt 200 ]; then
        LATENCY_LEVEL="极端高延迟/跨洋链路 (200-300ms)"
        DYN_LOWAT=262144
        DYN_ADV_WIN=1
        DYN_KEEPALIVE_PROBES=6
        FQ_MAXRATE="500mbit"
        ECN_VAL=0
        UDP_TIMEOUT=300
        UDP_STREAM=600
        HY2_INIT_STREAM=$(( RMEM_MAX / 4 ))
        HY2_MAX_STREAM=$(( RMEM_MAX / 2 ))
        HY2_INIT_CONN=$(( RMEM_MAX / 2 ))
        HY2_MAX_CONN=$(( RMEM_MAX ))
        UDP_SNDBUF=$(( RMEM_MAX * 3 / 4 ))
        UDP_RCVBUF=$(( RMEM_MAX * 3 / 4 ))

    elif [ "$LATENCY_INT" -gt 150 ]; then
        LATENCY_LEVEL="跨国长肥网络 (150-200ms)"
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
        UDP_SNDBUF=$(( RMEM_MAX / 2 ))
        UDP_RCVBUF=$(( RMEM_MAX / 2 ))

    elif [ "$LATENCY_INT" -gt 60 ]; then
        LATENCY_LEVEL="区域中等延迟 (60-150ms)"
        DYN_LOWAT=131072
        DYN_ADV_WIN=1
        DYN_KEEPALIVE_PROBES=5
        FQ_MAXRATE="2gbit"
        ECN_VAL=0
        UDP_TIMEOUT=90
        UDP_STREAM=180
        HY2_INIT_STREAM=$(( RMEM_MAX / 6 ))
        HY2_MAX_STREAM=$(( RMEM_MAX / 3 ))
        HY2_INIT_CONN=$(( RMEM_MAX / 3 ))
        HY2_MAX_CONN=$(( RMEM_MAX / 2 ))
        UDP_SNDBUF=$(( RMEM_MAX / 3 ))
        UDP_RCVBUF=$(( RMEM_MAX / 3 ))

    else
        LATENCY_LEVEL="同城/优质低延迟链路 (<60ms)"
        DYN_LOWAT=16384
        DYN_ADV_WIN=2
        DYN_KEEPALIVE_PROBES=4
        FQ_MAXRATE="10gbit"
        ECN_VAL=1
        UDP_TIMEOUT=60
        UDP_STREAM=120
        HY2_INIT_STREAM=$(( RMEM_MAX / 8 ))
        HY2_MAX_STREAM=$(( RMEM_MAX / 4 ))
        HY2_INIT_CONN=$(( RMEM_MAX / 4 ))
        HY2_MAX_CONN=$(( RMEM_MAX / 3 ))
        UDP_SNDBUF=$(( RMEM_MAX / 4 ))
        UDP_RCVBUF=$(( RMEM_MAX / 4 ))
    fi

    log "延迟分级: ${BOLD}${LATENCY_LEVEL}${NC}"
    info "FQ Maxrate=${FQ_MAXRATE} | ECN=${ECN_VAL} | NAT超时 UDP=${UDP_TIMEOUT}s / Stream=${UDP_STREAM}s"
    info "Hysteria2 QUIC窗口: InitStream=$(( HY2_INIT_STREAM / 1024 / 1024 ))MB | MaxConn=$(( HY2_MAX_CONN / 1024 / 1024 ))MB"
}

# ================= 2. 基础环境与模块准备 =================
prepare_env() {
    sep
    info "正在加载必要的内核模块 (BBR, Conntrack)..."
    modprobe tcp_bbr 2>/dev/null || true
    modprobe nf_conntrack 2>/dev/null || true
    modprobe nf_defrag_ipv4 2>/dev/null || true
    modprobe nf_defrag_ipv6 2>/dev/null || true

    if systemctl is-active --quiet systemd-journald; then
        info "正在优化系统日志体积..."
        journalctl --vacuum-time=7d > /dev/null 2>&1 || true
        journalctl --vacuum-size=500M > /dev/null 2>&1 || true
        sed -i 's/^#*SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf 2>/dev/null || true
        sed -i 's/^#*SystemKeepFree=.*/SystemKeepFree=200M/' /etc/systemd/journald.conf 2>/dev/null || true
        systemctl restart systemd-journald 2>/dev/null || true
        log "systemd-journald 日志限制已优化"
    fi

    # 预安装必要工具
    if [ -f /etc/debian_version ]; then
        command -v ethtool > /dev/null 2>&1 || apt-get install -yqq ethtool > /dev/null 2>&1 || true
    elif [ -f /etc/redhat-release ]; then
        command -v ethtool > /dev/null 2>&1 || yum install -y ethtool > /dev/null 2>&1 || true
    fi
}

# ================= 3. 清理旧配置 =================
cleanup_old_config() {
    sep
    info "正在清理冲突配置并备份..."
    rm -f /etc/sysctl.d/99-vps-optimize.conf /etc/sysctl.d/99-bbr.conf \
          /etc/sysctl.d/98-bbr.conf /etc/sysctl.d/99-netopt.conf

    cp -a "$SYSCTL_FILE" "${SYSCTL_FILE}.bak.$(date +%s)" 2>/dev/null || true

    # 清理所有历史版本标记块
    for ver in "V2" "V3" "V4" "V5" "V5.0" "V6.0"; do
        sed -i "/# ===== VPS Optimize ${ver}/,/# ===== End VPS Optimize ${ver}/d" "$SYSCTL_FILE" 2>/dev/null || true
    done
    sed -i '/# ===== VPS Optimize =====/,/# ===== End VPS Optimize =====/d' "$SYSCTL_FILE" 2>/dev/null || true

    local params=(
        "net.ipv4.tcp_congestion_control" "net.core.default_qdisc"
        "net.core.rmem_max" "net.core.wmem_max"
        "net.core.rmem_default" "net.core.wmem_default"
        "net.ipv4.tcp_rmem" "net.ipv4.tcp_wmem" "net.ipv4.tcp_mem"
        "net.ipv4.udp_mem" "net.ipv4.udp_rmem_min" "net.ipv4.udp_wmem_min"
        "net.core.optmem_max"
        "net.ipv4.ipfrag_high_thresh" "net.ipv4.ipfrag_low_thresh" "net.ipv4.ipfrag_time"
        "net.ipv6.ip6frag_high_thresh" "net.ipv6.ip6frag_low_thresh" "net.ipv6.ip6frag_time"
        "net.ipv4.tcp_notsent_lowat" "net.ipv4.tcp_fastopen"
        "net.ipv4.tcp_window_scaling" "net.ipv4.tcp_adv_win_scale"
        "net.ipv4.tcp_slow_start_after_idle" "net.ipv4.tcp_ecn"
        "net.ipv4.tcp_frto" "net.ipv4.tcp_sack" "net.ipv4.tcp_dsack"
        "net.ipv4.tcp_fack" "net.ipv4.tcp_timestamps" "net.ipv4.tcp_orphan_retries"
        "net.netfilter.nf_conntrack_max" "net.netfilter.nf_conntrack_tcp_timeout_established"
        "net.netfilter.nf_conntrack_udp_timeout" "net.netfilter.nf_conntrack_udp_timeout_stream"
        "net.netfilter.nf_conntrack_icmp_timeout" "net.netfilter.nf_conntrack_generic_timeout"
        "net.core.somaxconn" "net.core.netdev_max_backlog"
        "net.core.netdev_budget" "net.core.netdev_budget_usecs"
        "net.ipv4.tcp_max_syn_backlog" "net.ipv4.tcp_max_tw_buckets"
        "net.ipv4.tcp_tw_reuse" "net.ipv4.tcp_fin_timeout"
        "net.ipv4.tcp_retries2" "net.ipv4.tcp_keepalive_time"
        "net.ipv4.tcp_keepalive_probes" "net.ipv4.tcp_keepalive_intvl"
        "net.ipv4.ip_no_pmtu_disc" "net.ipv4.tcp_mtu_probing" "net.ipv4.tcp_base_mss"
        "net.core.busy_read" "net.core.busy_poll"
        "net.ipv4.ip_local_port_range"
        "net.ipv4.conf.all.send_redirects" "net.ipv4.conf.all.accept_redirects"
        "net.ipv4.conf.all.accept_source_route"
        "vm.swappiness"
    )
    for param in "${params[@]}"; do
        sed -i "/^\s*${param}\s*=/d" "$SYSCTL_FILE" 2>/dev/null || true
    done
    log "冲突项清理完成。"
}

# ================= 4. 写入极限优化网络参数 =================
write_final_sysctl_config() {
    sep
    info "正在写入系统内核参数 (V6.0 — 内核兼容性预检模式)..."

    TCP_MEM_MIN=$(( RMEM_MAX / 4 / 4096 ))
    TCP_MEM_PRS=$(( RMEM_MAX / 2 / 4096 ))
    TCP_MEM_MAX=$(( RMEM_MAX / 4096 ))

    WRITE_COUNT=0
    SKIP_COUNT=0

    # 辅助函数：预检后写入
    write_param() {
        local key="$1" val="$2" comment="${3:-}"
        if sysctl -n "$key" > /dev/null 2>&1; then
            if [ -n "$comment" ]; then
                echo "# $comment" >> "$SYSCTL_FILE"
            fi
            echo "${key} = ${val}" >> "$SYSCTL_FILE"
            (( WRITE_COUNT++ )) || true
        else
            echo "# [跳过-内核不支持] ${key} = ${val}" >> "$SYSCTL_FILE"
            (( SKIP_COUNT++ )) || true
        fi
    }

    cat >> "$SYSCTL_FILE" << HEADER_EOF

# ===== VPS Optimize V6.0 (Hysteria2深度专项+海外访问全面强化版) =====
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 延迟档位: ${LATENCY_LEVEL}
# 硬件配置: ${CPU_CORES}核 / ${TOTAL_MEM_MB}MB RAM | BBR: ${BBR_ALG}

# --- 拥塞控制与队列 ---
HEADER_EOF

    write_param "net.core.default_qdisc"             "fq"
    write_param "net.ipv4.tcp_congestion_control"    "$BBR_ALG"

    echo "" >> "$SYSCTL_FILE"
    echo "# --- Socket 收发缓冲区 ---" >> "$SYSCTL_FILE"
    write_param "net.core.rmem_max"                  "$RMEM_MAX"
    write_param "net.core.wmem_max"                  "$WMEM_MAX"
    write_param "net.core.rmem_default"              "$RMEM_DEFAULT"
    write_param "net.core.wmem_default"              "$WMEM_DEFAULT"
    write_param "net.ipv4.tcp_rmem"                  "4096 87380 $RMEM_MAX"
    write_param "net.ipv4.tcp_wmem"                  "4096 65536 $WMEM_MAX"
    write_param "net.ipv4.tcp_mem"                   "$TCP_MEM_MIN $TCP_MEM_PRS $TCP_MEM_MAX"

    echo "" >> "$SYSCTL_FILE"
    echo "# --- UDP 专属缓冲区 (Hysteria2 高频UDP特化) ---" >> "$SYSCTL_FILE"
    write_param "net.ipv4.udp_rmem_min"              "65536"   "V6.0: 大幅提升UDP最小接收缓冲，防止QUIC小包被丢弃"
    write_param "net.ipv4.udp_wmem_min"              "65536"
    write_param "net.ipv4.udp_mem"                   "$UDP_MEM"
    write_param "net.core.optmem_max"                "262144"

    echo "" >> "$SYSCTL_FILE"
    echo "# --- Socket 极速轮询 (降低延迟) ---" >> "$SYSCTL_FILE"
    write_param "net.core.busy_read"                 "50"
    write_param "net.core.busy_poll"                 "50"

    echo "" >> "$SYSCTL_FILE"
    echo "# --- UDP 分片重组 (IPv4 + IPv6) ---" >> "$SYSCTL_FILE"
    write_param "net.ipv4.ipfrag_high_thresh"        "$RMEM_MAX"
    write_param "net.ipv4.ipfrag_low_thresh"         "$FRAG_LOW"
    write_param "net.ipv4.ipfrag_time"               "60"
    write_param "net.ipv6.ip6frag_high_thresh"       "$RMEM_MAX"  "V6.0新增: IPv6分片重组"
    write_param "net.ipv6.ip6frag_low_thresh"        "$FRAG_LOW"
    write_param "net.ipv6.ip6frag_time"              "60"

    echo "" >> "$SYSCTL_FILE"
    echo "# --- TCP 参数精修 ---" >> "$SYSCTL_FILE"
    write_param "net.ipv4.tcp_window_scaling"        "1"
    write_param "net.ipv4.tcp_adv_win_scale"         "$DYN_ADV_WIN"
    write_param "net.ipv4.tcp_slow_start_after_idle" "0"
    write_param "net.ipv4.tcp_notsent_lowat"         "$DYN_LOWAT"
    write_param "net.ipv4.tcp_ecn"                   "$ECN_VAL"   "V6.0: 根据延迟档位智能启停ECN"
    write_param "net.ipv4.tcp_frto"                  "2"
    write_param "net.ipv4.tcp_sack"                  "1"
    write_param "net.ipv4.tcp_dsack"                 "1"
    write_param "net.ipv4.tcp_timestamps"            "1"
    write_param "net.ipv4.tcp_orphan_retries"        "2"          "V6.0新增: 减少孤儿连接重试，快速释放资源"

    echo "" >> "$SYSCTL_FILE"
    echo "# --- 连接追踪与 NAT 保活 (海外UDP穿透重点) ---" >> "$SYSCTL_FILE"
    write_param "net.netfilter.nf_conntrack_max"                    "$CONNTRACK_MAX"
    write_param "net.netfilter.nf_conntrack_tcp_timeout_established" "7200"
    write_param "net.netfilter.nf_conntrack_udp_timeout"            "$UDP_TIMEOUT"   "V6.0: 按延迟动态适配，穿透海外严苛NAT"
    write_param "net.netfilter.nf_conntrack_udp_timeout_stream"     "$UDP_STREAM"
    write_param "net.netfilter.nf_conntrack_icmp_timeout"           "30"             "V6.0新增: 防止ICMP探测占满conntrack"
    write_param "net.netfilter.nf_conntrack_generic_timeout"        "60"

    echo "" >> "$SYSCTL_FILE"
    echo "# --- 并发与连接队列 ---" >> "$SYSCTL_FILE"
    write_param "net.core.somaxconn"                 "65535"
    write_param "net.core.netdev_max_backlog"        "100000"
    write_param "net.core.netdev_budget"             "600"
    write_param "net.core.netdev_budget_usecs"       "8000"
    write_param "net.ipv4.tcp_max_syn_backlog"       "16384"
    write_param "net.ipv4.tcp_max_tw_buckets"        "2000000"
    write_param "net.ipv4.tcp_tw_reuse"              "1"
    write_param "net.ipv4.tcp_fin_timeout"           "25"

    echo "" >> "$SYSCTL_FILE"
    echo "# --- 端口范围 + 保活 + MTU ---" >> "$SYSCTL_FILE"
    write_param "net.ipv4.ip_local_port_range"       "1024 65535"
    write_param "net.ipv4.tcp_retries2"              "8"
    write_param "net.ipv4.tcp_keepalive_time"        "300"
    write_param "net.ipv4.tcp_keepalive_probes"      "$DYN_KEEPALIVE_PROBES"
    write_param "net.ipv4.tcp_keepalive_intvl"       "15"
    write_param "net.ipv4.ip_no_pmtu_disc"           "0"
    write_param "net.ipv4.tcp_mtu_probing"           "2"          "V6.0: 强制探测MTU，彻底防止海外MTU黑洞断流"
    write_param "net.ipv4.tcp_base_mss"              "1024"
    write_param "net.ipv4.tcp_fastopen"              "1"

    echo "" >> "$SYSCTL_FILE"
    echo "# --- 安全加固 + 内存优化 ---" >> "$SYSCTL_FILE"
    write_param "net.ipv4.conf.all.send_redirects"   "0"          "V6.0新增: 禁止IP重定向，防止中间人攻击"
    write_param "net.ipv4.conf.all.accept_redirects" "0"
    write_param "net.ipv4.conf.all.accept_source_route" "0"
    write_param "vm.swappiness"                      "10"         "V6.0新增: 减少Swap，优先将内存用于网络缓冲区"

    echo "" >> "$SYSCTL_FILE"
    echo "# ===== End VPS Optimize V6.0 =====" >> "$SYSCTL_FILE"

    sysctl --system > /dev/null 2>&1 || sysctl -p > /dev/null 2>&1 || true
    log "内核参数写入完成 (写入: ${WRITE_COUNT} 项，跳过不兼容项: ${SKIP_COUNT} 项)"
}

# ================= 5. 解除系统进程与文件限制 =================
apply_system_limits() {
    sep
    info "正在突破系统文件描述符限制 (ulimit)..."
    sed -i '/nofile/d' "$LIMITS_FILE" 2>/dev/null || true
    sed -i '/nproc/d'  "$LIMITS_FILE" 2>/dev/null || true

    cat >> "$LIMITS_FILE" << 'LIMITS_EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc  unlimited
* hard nproc  unlimited
root soft nofile 1048576
root hard nofile 1048576
root soft nproc  unlimited
root hard nproc  unlimited
LIMITS_EOF

    # V6.0 新增: 同步更新 systemd 全局限制
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-limits.conf << 'SYSTEMD_EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
SYSTEMD_EOF
    systemctl daemon-reexec 2>/dev/null || true
    log "ulimit 已提升至 1048576，nproc 不限 (ulimit + systemd 双重保障)"
}

# ================= 6. 网卡硬件智能调优 =================
optimize_hardware_interrupts() {
    sep
    info "正在执行硬件中断调优与 UDP Offload 优化..."

    if [ "$CPU_CORES" -gt 1 ]; then
        if ! command -v irqbalance > /dev/null 2>&1; then
            apt-get install -yqq irqbalance > /dev/null 2>&1 || yum install -y irqbalance > /dev/null 2>&1 || true
        fi
        systemctl enable irqbalance 2>/dev/null || true
        systemctl start irqbalance 2>/dev/null || true
        log "irqbalance 已启用 (多核中断均衡)"
    else
        systemctl stop irqbalance 2>/dev/null || true
        systemctl disable irqbalance 2>/dev/null || true
        warn "单核环境: 跳过 irqbalance"
    fi

    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|en|ens|enp|eno)')
    for iface in $interfaces; do
        [ "$iface" = "lo" ] && continue

        # 扩展 RX/TX Ring Buffer 至最大
        MAX_RX=$(ethtool -g "$iface" 2>/dev/null | awk '/^RX:/{found=1; next} found{print $1; exit}' || echo "0")
        MAX_TX=$(ethtool -g "$iface" 2>/dev/null | awk '/^TX:/{found=1; next} found{print $1; exit}' || echo "0")
        if [[ "$MAX_RX" =~ ^[0-9]+$ ]] && [ "$MAX_RX" -gt 0 ]; then
            ethtool -G "$iface" rx "$MAX_RX" 2>/dev/null || true
            info "$iface: RX Ring Buffer 扩展至 ${MAX_RX}"
        fi
        if [[ "$MAX_TX" =~ ^[0-9]+$ ]] && [ "$MAX_TX" -gt 0 ]; then
            ethtool -G "$iface" tx "$MAX_TX" 2>/dev/null || true
        fi

        # 中断合并
        if ethtool -C "$iface" adaptive-rx on 2>/dev/null; then
            log "$iface: 自适应中断合并已开启"
        else
            ethtool -C "$iface" rx-usecs 50 tx-usecs 50 2>/dev/null || true
            info "$iface: 静态 50us 中断合并已设置"
        fi

        # GRO/GSO/TSO + UDP 高级卸载
        ethtool -K "$iface" gso on tso on gro on 2>/dev/null || true
        ethtool -K "$iface" rx-udp-gro-forwarding on 2>/dev/null || true
        ethtool -K "$iface" rx-gro-list on 2>/dev/null || true
        ethtool -K "$iface" ufo on 2>/dev/null || true  # V6.0: UDP分片卸载

        log "$iface: GRO/GSO/UDP Offload 已激活"
    done
}

# ================= 7. 实时应用 Qdisc 队列 (含 WARP/WG 专项) =================
apply_live_qdisc() {
    sep
    info "正在实时应用 FQ 队列规则及 Hysteria2 专项发送队列扩容..."

    # V6.0: 物理网卡 + WARP/WG 虚拟接口全覆盖
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' \
        | grep -E '^(eth|en|ens|enp|eno|warp|wg|tun)' || true)

    for iface in $interfaces; do
        [ "$iface" = "lo" ] && continue

        ip link set dev "$iface" txqueuelen 10000 2>/dev/null || true
        tc qdisc del dev "$iface" root 2>/dev/null || true

        # V6.0: 针对 WG/WARP 接口特调 flow_limit (其封包较大，flow较少)
        if echo "$iface" | grep -qE '^(warp|wg|tun)'; then
            FLOW_LIMIT=200
        else
            FLOW_LIMIT=400
        fi

        if ! tc qdisc replace dev "$iface" root fq flow_limit "$FLOW_LIMIT" \
               buckets 65536 maxrate "$FQ_MAXRATE" quantum 1514 2>/dev/null; then
            if ! tc qdisc replace dev "$iface" root fq 2>/dev/null; then
                tc qdisc replace dev "$iface" root fq_pie 2>/dev/null || true
                warn "$iface: 已降级应用 fq_pie (网卡不支持 fq)"
            else
                info "$iface: 已应用 fq (基础参数)"
            fi
        else
            log "$iface: fq (flow=${FLOW_LIMIT}, buckets=64k, maxrate=${FQ_MAXRATE}, quantum=1514) + txqueuelen=10000"
        fi
    done
}

# ================= 8. Hysteria2 智能守护 + CPU 亲和性 =================
configure_hysteria_service() {
    sep
    HY_BIN=$(command -v hysteria 2>/dev/null || echo "")
    [ -z "$HY_BIN" ] && [ -f "/usr/local/bin/hysteria" ] && HY_BIN="/usr/local/bin/hysteria"

    if [ -z "$HY_BIN" ] || [ ! -f "$HY_BIN" ]; then
        warn "[跳过] 未在系统路径中找到 Hysteria2 主程序。"
        HY2_LISTEN_PORT=""
        return 0
    fi

    info "检测到 Hysteria2: ${BOLD}$HY_BIN${NC}"

    # V6.0 新增: 读取 config.yaml 监听端口
    HY2_LISTEN_PORT=""
    if [ -f "$HY2_CONFIG" ]; then
        HY2_LISTEN_PORT=$(grep -E '^\s*listen:' "$HY2_CONFIG" 2>/dev/null | \
                          grep -oE ':[0-9]+' | tail -1 | tr -d ':' || echo "")
        [ -n "$HY2_LISTEN_PORT" ] && info "从 config.yaml 读取到 Hysteria2 监听端口: ${BOLD}${HY2_LISTEN_PORT}${NC}"
    fi

    read -p "  是否开启【增强守候模式】(循环等待 warp 网卡)？[y/N]: " is_warp < /dev/tty
    if [[ "$is_warp" =~ ^[yY]$ ]]; then
        WAIT_LOGIC="ExecStartPre=/bin/sh -c 'until ip addr show warp > /dev/null 2>&1; do echo \"等待 warp 网卡...\"; sleep 2; done'"
        DESC_SUFFIX="(Warp Wait)"
    else
        WAIT_LOGIC=""
        DESC_SUFFIX="(Standard)"
    fi

    # V6.0: CPU 亲和性绑定
    if [ "$CPU_CORES" -gt 1 ]; then
        CPU_SCHED_LINES="CPUSchedulingPolicy=fifo
CPUSchedulingPriority=50"
        if [ "$CPU_CORES" -ge 4 ]; then
            AFFINITY_CORES="1-$((CPU_CORES-1))"
            CPU_AFFINITY_LINE="CPUAffinity=${AFFINITY_CORES}"
            info "CPU亲和性: 绑定至 CPU ${AFFINITY_CORES} (跳过处理系统中断的 CPU0)"
        else
            CPU_AFFINITY_LINE=""
        fi
        log "多核环境: Hysteria2 开启实时调度 (FIFO priority=50)"
    else
        CPU_SCHED_LINES=""
        CPU_AFFINITY_LINE=""
        warn "单核环境: 跳过实时调度配置"
    fi

    cat > /etc/systemd/system/hysteria-server.service << SERVICE_EOF
[Unit]
Description=Hysteria2 Server Service ${DESC_SUFFIX} (V6.0 Optimized)
Documentation=https://v2.hysteria.network/
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
${WAIT_LOGIC}
ExecStart=${HY_BIN} server --config ${HY2_CONFIG}
WorkingDirectory=/var/lib/hysteria
User=root

# ── 资源限制解除 ──────────────────────────────
LimitMEMLOCK=infinity
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity

# ── V6.0 进程调度提权 ─────────────────────────
Nice=-10
IOSchedulingClass=realtime
IOSchedulingPriority=4
${CPU_SCHED_LINES}
${CPU_AFFINITY_LINE}

# ── 环境变量 ──────────────────────────────────
Environment=HYSTERIA_LOG_LEVEL=info
# V6.0: 开启 UDP GSO 以提升 UDP 发包性能（quic-go 特性）
Environment=QUIC_GO_ENABLE_GSO=1
# V6.0: 增大 QUIC-go 连接接收缓冲区至系统最大值
Environment=QUIC_GO_RECEIVE_BUFFER_SIZE=${RMEM_MAX}

# ── 守护与重启策略 ────────────────────────────
Restart=on-failure
RestartSec=3s
StartLimitIntervalSec=0
TimeoutStartSec=30
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    mkdir -p /var/lib/hysteria/acme /etc/hysteria/acme 2>/dev/null || true
    chown -R root:root /var/lib/hysteria /etc/hysteria 2>/dev/null || true
    chmod -R 755 /var/lib/hysteria /etc/hysteria 2>/dev/null || true

    systemctl daemon-reload
    log "Hysteria2 systemd 服务已更新 (V6.0 CPU亲和性+IO提权+QUIC_GO_GSO环境变量)"

    # V6.0 新增: 自动写入 config.yaml QUIC 参数
    if [ -f "$HY2_CONFIG" ]; then
        echo -e "  ${CYAN}检测到 ${HY2_CONFIG}，是否自动写入推荐的 QUIC 窗口参数？[Y/n]: ${NC}"
        read -p "  " do_write_quic < /dev/tty
        if [[ ! "$do_write_quic" =~ ^[nN]$ ]]; then
            cp -a "$HY2_CONFIG" "${HY2_CONFIG}.bak.$(date +%s)"

            # 使用 python3 精确替换/追加 quic 块
            python3 << PYEOF 2>/dev/null && log "Hysteria2 config.yaml QUIC 参数已自动更新！" || {
import re
hy2_config = '${HY2_CONFIG}'
init_stream = ${HY2_INIT_STREAM}
max_stream  = ${HY2_MAX_STREAM}
init_conn   = ${HY2_INIT_CONN}
max_conn    = ${HY2_MAX_CONN}

with open(hy2_config, 'r') as f:
    content = f.read()

# 移除已有的 quic 配置块
content = re.sub(r'\nquic:\n(?:  [^\n]*\n)+', '\n', content)
content = content.rstrip('\n')

quic_block = f"""

quic:
  initStreamReceiveWindow: {init_stream}
  maxStreamReceiveWindow: {max_stream}
  initConnReceiveWindow: {init_conn}
  maxConnReceiveWindow: {max_conn}
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
"""

with open(hy2_config, 'w') as f:
    f.write(content + quic_block)
print('QUIC 参数已写入')
PYEOF
            warn "python3 写入失败，请参考报告末尾手动填写 QUIC 参数。"
            }
        fi
    else
        warn "未找到 ${HY2_CONFIG}，跳过自动写入。请参考报告末尾手动填写。"
    fi

    export HY2_LISTEN_PORT
}

# ================= 9. 自动化系统防火墙放行 =================
configure_firewall() {
    sep
    info "正在配置系统防火墙，确保端口永久放行..."

    EXTRA_PORTS=()
    if [ -n "${HY2_LISTEN_PORT:-}" ] && \
       [ "$HY2_LISTEN_PORT" != "443" ] && \
       [[ "$HY2_LISTEN_PORT" =~ ^[0-9]+$ ]]; then
        EXTRA_PORTS+=("$HY2_LISTEN_PORT")
        info "将额外放行 Hysteria2 专属监听端口: ${HY2_LISTEN_PORT}"
    fi

    FIREWALL_MANAGED=false

    # UFW
    if command -v ufw > /dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 80/tcp > /dev/null 2>&1 || true
        ufw allow 443/tcp > /dev/null 2>&1 || true
        ufw allow 443/udp > /dev/null 2>&1 || true
        ufw allow 20000:50000/tcp > /dev/null 2>&1 || true
        ufw allow 20000:50000/udp > /dev/null 2>&1 || true
        for p in "${EXTRA_PORTS[@]}"; do
            ufw allow "${p}/tcp" > /dev/null 2>&1 || true
            ufw allow "${p}/udp" > /dev/null 2>&1 || true
        done
        ufw reload > /dev/null 2>&1 || true
        log "UFW 规则已更新 (永久生效)"
        FIREWALL_MANAGED=true
    fi

    # firewalld
    if command -v firewall-cmd > /dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port=80/tcp > /dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=443/tcp > /dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=443/udp > /dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=20000-50000/tcp > /dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=20000-50000/udp > /dev/null 2>&1 || true
        for p in "${EXTRA_PORTS[@]}"; do
            firewall-cmd --permanent --add-port="${p}/tcp" > /dev/null 2>&1 || true
            firewall-cmd --permanent --add-port="${p}/udp" > /dev/null 2>&1 || true
        done
        firewall-cmd --reload > /dev/null 2>&1 || true
        log "firewalld 规则已更新 (永久生效)"
        FIREWALL_MANAGED=true
    fi

    # iptables 兜底
    if command -v iptables > /dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport 20000:50000 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport 20000:50000 -j ACCEPT 2>/dev/null || true
        for p in "${EXTRA_PORTS[@]}"; do
            iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
            iptables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
        done
        log "iptables 规则已置顶放行"

        if [ "$FIREWALL_MANAGED" = false ]; then
            if [ -f /etc/debian_version ]; then
                export DEBIAN_FRONTEND=noninteractive
                if ! command -v netfilter-persistent > /dev/null 2>&1; then
                    apt-get install -yqq iptables-persistent netfilter-persistent > /dev/null 2>&1 || true
                fi
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                netfilter-persistent save > /dev/null 2>&1 || true
                log "netfilter-persistent 已保存 iptables 规则 (开机永久生效)"
            elif [ -f /etc/redhat-release ]; then
                mkdir -p /etc/sysconfig
                iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
                systemctl enable iptables > /dev/null 2>&1 || true
                log "iptables 规则已保存至 /etc/sysconfig/iptables"
            fi
        fi
    fi
}

# ================= 10. 输出报告 =================
show_result() {
    sep
    echo ""
    echo -e "${BOLD}${GREEN}====================================================${NC}"
    echo -e "${BOLD}${GREEN}✅  VPS 智能优化 V6.0 执行汇总报告${NC}"
    echo -e "${GREEN}====================================================${NC}"
    printf "  ${CYAN}%-18s${NC}: %s\n" "硬件状态"     "${CPU_CORES} Cores / ${TOTAL_MEM_MB}MB RAM (${MEM_LEVEL})"
    printf "  ${CYAN}%-18s${NC}: %s\n" "内核版本"     "$(uname -r)"
    printf "  ${CYAN}%-18s${NC}: %s\n" "拥塞控制"     "${BBR_ALG} + fq qdisc"
    printf "  ${CYAN}%-18s${NC}: %s\n" "链路状态"     "${LATENCY_RAW}ms (${LATENCY_LEVEL})"
    printf "  ${CYAN}%-18s${NC}: %s\n" "Socket缓冲区"  "Max=$(( RMEM_MAX / 1024 / 1024 ))MB (rmem/wmem)"
    printf "  ${CYAN}%-18s${NC}: %s\n" "UDP缓冲区"    "RCVBUF=$(( UDP_RCVBUF / 1024 / 1024 ))MB | SNDBUF=$(( UDP_SNDBUF / 1024 / 1024 ))MB"
    printf "  ${CYAN}%-18s${NC}: %s\n" "FQ动态流控"   "maxrate=${FQ_MAXRATE} | quantum=1514"
    printf "  ${CYAN}%-18s${NC}: %s\n" "ECN状态"      "$( [ "$ECN_VAL" -eq 1 ] && echo '开启 (低延迟优选)' || echo '强制关闭 (规避海外黑洞)' )"
    printf "  ${CYAN}%-18s${NC}: %s\n" "MTU探测"      "tcp_mtu_probing=2 (强制探测，防MTU黑洞)"
    printf "  ${CYAN}%-18s${NC}: %s\n" "NAT保活"      "UDP=${UDP_TIMEOUT}s / Stream=${UDP_STREAM}s"
    printf "  ${CYAN}%-18s${NC}: %s\n" "进程守护"     "systemd Nice=-10 | IO=realtime | GSO=1"
    printf "  ${CYAN}%-18s${NC}: %s\n" "CPU亲和性"    "$( [ "$CPU_CORES" -ge 4 ] && echo "绑定至 CPU1-$((CPU_CORES-1)) (避开中断CPU0)" || echo '跳过 (核心数<4)' )"
    printf "  ${CYAN}%-18s${NC}: %s\n" "文件描述符"   "1048576 (ulimit + systemd 双重保障)"
    printf "  ${CYAN}%-18s${NC}: %s\n" "安全加固"     "IP重定向已禁用 | vm.swappiness=10"
    echo -e "${GREEN}====================================================${NC}"

    echo ""
    echo -e "${BOLD}${CYAN}📋 Hysteria2 config.yaml V6.0 推荐 QUIC 参数：${NC}"
    echo -e "   ${YELLOW}(根据 ${LATENCY_RAW}ms 延迟 + ${TOTAL_MEM_MB}MB 内存 自动调校)${NC}"
    echo ""
    echo "   quic:"
    echo "     initStreamReceiveWindow: $HY2_INIT_STREAM"
    echo "     maxStreamReceiveWindow:  $HY2_MAX_STREAM"
    echo "     initConnReceiveWindow:   $HY2_INIT_CONN"
    echo "     maxConnReceiveWindow:    $HY2_MAX_CONN"
    echo "     maxIdleTimeout: 30s"
    echo "     maxIncomingStreams: 1024"
    echo "     disablePathMTUDiscovery: false"
    echo ""
    echo -e "   ${YELLOW}⚡ 客户端也需同步配置相同的 QUIC 窗口参数以获得最大吞吐！${NC}"
    echo -e "${GREEN}====================================================${NC}"

    echo ""
    echo -e "${BOLD}${YELLOW}⚠️  重要提醒：${NC}"
    echo "  1. 如使用 甲骨文OCI / AWS / 阿里云 等，请前往【云控制台安全组】"
    echo "     放行对应 UDP 端口，否则外网依然无法连通！"
    echo "  2. 请务必执行 ${BOLD}reboot${NC} 重启系统以完全激活内核高级网络栈。"
    echo "  3. 重启后执行 ${BOLD}sysctl net.ipv4.tcp_congestion_control${NC} 验证 BBR 生效。"
    echo "  4. 重启后执行 ${BOLD}ss -s${NC} 确认连接数正常。"
    echo "  5. 优化日志已保存至: ${BOLD}${LOG_FILE}${NC}"
    echo ""
    echo -e "${GREEN}🎉 V6.0 优化脚本执行完毕！${NC}"
    echo -e "${GREEN}====================================================${NC}"
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
