#!/bin/bash

# ====================================================
# 脚本功能：内核基础优化 + TCP 并发/Fast Open 优化 + Hysteria2 交互守候
# 适用系统：Debian 11+, Ubuntu 20.04+ (Root 权限执行)
# ====================================================

# 1. 内核参数综合优化 (BBR + MTU + 并发队列 + TFO)
echo "正在优化内核网络参数 (包含 TCP Fast Open 与 并发队列)..."
cat <<EOF > /etc/sysctl.d/99-vps-optimize.conf
# --- 基础拥塞控制 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- 路径 MTU 探测 ---
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.tcp_mtu_probing = 1

# --- [新增加项] TCP Fast Open (TFO) ---
# 3 代表同时开启服务端和客户端支持，减少握手延迟
net.ipv4.tcp_fastopen = 3

# --- [新增加项] 提升并发处理能力 (全连接/半连接队列) ---
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 8192

# --- 增大 TCP 缓冲区 (针对高延迟 200ms+ 优化) ---
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# --- 优化连接回收与慢启动 ---
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fin_timeout = 25
EOF

# 应用 sysctl 配置
sysctl --system >/dev/null 2>&1
echo "  - 内核参数已应用。"

# 2. 队列管理优化 (针对所有物理/虚拟网卡)
echo "正在配置网卡队列规则 (FQ)..."
interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|en|warp)')
for iface in $interfaces; do
    tc qdisc replace dev "$iface" root fq 2>/dev/null
    echo "  - 已为 $iface 启用 FQ"
done

# 3. Hysteria2 Systemd 服务配置 (交互式决策)
echo "----------------------------------------------------"
if [ -f "/usr/local/bin/hysteria" ]; then
    echo "检测到 Hysteria2 已安装，准备配置 Systemd 服务。"
    echo "是否开启【增强守候模式】？(该模式会循环等待 warp 网卡加载，适合落地机)"
    read -p "开启请输入 y，关闭（使用标准模式）请输入 n [y/n]: " is_warp

    if [[ "$is_warp" == "y" || "$is_warp" == "Y" ]]; then
        WAIT_LOGIC="ExecStartPre=/bin/sh -c 'until ip addr show warp >/dev/null 2>&1; do sleep 2; done'"
        DESC_SUFFIX="(带 Warp 等待逻辑)"
        echo "--> 已确认：开启增强守候。"
    else
        WAIT_LOGIC=""
        DESC_SUFFIX="(标准模式)"
        echo "--> 已确认：关闭增强守候。"
    fi

    # 写入配置文件
    cat <<EOF > /etc/systemd/system/hysteria-server.service
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

    # 权限与目录初始化
    mkdir -p /var/lib/hysteria
    chown -R hysteria:hysteria /var/lib/hysteria

    systemctl daemon-reload
    echo "  - Hysteria2 服务配置完成。"
else
    echo "  - 未检测到 Hysteria2 主程序，跳过服务配置。"
fi

echo "===================================================="
echo "所有优化已完成！"
echo "您可以执行 'systemctl restart hysteria-server' 来使服务生效。"
echo "===================================================="
