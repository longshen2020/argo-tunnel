#!/usr/bin/env bash
#====================================================
# Argo Tunnel 全能面板 v4.0
# 证书模式全自动 / Alpine兼容 / 开机自启
#====================================================

set -e

# 配置路径
CONF_FILE="/etc/argo-tunnel.conf"
LOG_FILE="/var/log/cloudflared.log"
PID_FILE="/var/run/cloudflared.pid"
SCRIPT_PATH="/usr/local/bin/argo"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

print_color() { echo -e "${1}${2}${NC}"; }
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_color "$RED" "请使用 root 权限运行此脚本！"
        print_color "$YELLOW" "执行: sudo $0"
        exit 1
    fi
}

# 确保 bash 存在（Alpine 修复）
ensure_bash() {
    if ! command -v bash &>/dev/null; then
        print_color "$YELLOW" "系统未安装 bash，正在自动安装..."
        if [ -f /etc/alpine-release ]; then
            apk add --no-cache bash
        else
            apt-get update -y && apt-get install -y bash
        fi
        # 重新用 bash 执行当前脚本
        exec bash "$0" "$@"
    fi
}

# 检测系统及包管理器
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
    else
        print_color "$RED" "无法识别系统"
        exit 1
    fi
    case "$OS_ID" in
        debian|ubuntu) PKG_MANAGER="apt-get"; INSTALL_CMD="apt-get install -y"; REMOVE_CMD="apt-get remove -y" ;;
        alpine) PKG_MANAGER="apk"; INSTALL_CMD="apk add --no-cache"; REMOVE_CMD="apk del" ;;
        *) print_color "$RED" "不支持的系统"; exit 1 ;;
    esac
}

# 初始化配置
init_config() {
    [ ! -f "$CONF_FILE" ] && cat > "$CONF_FILE" <<EOF
MODE=quick
LOCAL_PORT=8080
TUNNEL_TOKEN=""
FIXED_DOMAIN=""
TUNNEL_NAME=""
TUNNEL_UUID=""
CUSTOM_DOMAIN=""
EOF
    source "$CONF_FILE"
}

update_config() {
    local k="$1" v="$2"
    grep -q "^${k}=" "$CONF_FILE" && sed -i "s|^${k}=.*|${k}=${v}|" "$CONF_FILE" || echo "${k}=${v}" >> "$CONF_FILE"
    source "$CONF_FILE"
}

#=================== cloudflared 安装/卸载 ===================
install_cloudflared() {
    detect_os
    print_color "$CYAN" "安装 cloudflared..."
    case "$OS_ID" in
        debian|ubuntu)
            curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" > /etc/apt/sources.list.d/cloudflared.list
            apt-get update -y >/dev/null && $INSTALL_CMD cloudflared
            ;;
        alpine)
            ARCH=$(uname -m)
            case "$ARCH" in
                x86_64) BIN="cloudflared-linux-amd64" ;;
                aarch64) BIN="cloudflared-linux-arm64" ;;
                armv7l) BIN="cloudflared-linux-arm" ;;
                *) print_color "$RED" "架构不支持"; return 1 ;;
            esac
            wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/${BIN}" -O /usr/local/bin/cloudflared
            chmod +x /usr/local/bin/cloudflared
            ;;
    esac
    command -v cloudflared &>/dev/null && print_color "$GREEN" "安装成功" || print_color "$RED" "安装失败"
}

uninstall_cloudflared() {
    stop_tunnel 2>/dev/null
    detect_os
    case "$OS_ID" in
        debian|ubuntu) $REMOVE_CMD cloudflared; rm -f /etc/apt/sources.list.d/cloudflared.list ;;
        alpine) rm -f /usr/local/bin/cloudflared ;;
    esac
    print_color "$GREEN" "已卸载"
}

#=================== 证书模式一键部署（全新） ===================
cert_auto_setup() {
    init_config
    read -p "请输入完整的自定义域名 (如 sub.example.com): " full_domain
    [ -z "$full_domain" ] && { print_color "$RED" "域名不能为空"; return 1; }

    # 提取隧道名称（第一个点之前的部分）
    local tname="${full_domain%%.*}"
    if [ -z "$tname" ] || [ "$tname" = "$full_domain" ]; then
        print_color "$RED" "域名格式错误，需包含子域名"
        return 1
    fi

    read -p "本地转发端口 (默认 $LOCAL_PORT): " lport
    if [[ "$lport" =~ ^[0-9]+$ ]] && [ "$lport" -ge 1 ] && [ "$lport" -le 65535 ]; then
        LOCAL_PORT=$lport
    fi

    # 检查是否已有证书，若无则执行登录
    if [ ! -f /etc/cloudflared/cert.pem ]; then
        print_color "$CYAN" "未检测到授权证书，正在打开网页授权..."
        cloudflared tunnel login
        if [ -f ~/.cloudflared/cert.pem ]; then
            mkdir -p /etc/cloudflared
            cp ~/.cloudflared/cert.pem /etc/cloudflared/cert.pem
            print_color "$GREEN" "授权成功"
        else
            print_color "$RED" "授权失败，请重试"
            return 1
        fi
    else
        print_color "$GREEN" "已存在授权证书，跳过登录"
    fi

    # 创建隧道
    print_color "$CYAN" "正在创建隧道 $tname ..."
    local uuid
    uuid=$(cloudflared tunnel create "$tname" 2>&1 | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
    if [ -z "$uuid" ]; then
        print_color "$RED" "隧道创建失败，请检查输出"
        return 1
    fi

    # 复制凭据
    mkdir -p /etc/cloudflared
    local cred_file
    cred_file=$(ls ~/.cloudflared/${tname}.json 2>/dev/null || ls ~/.cloudflared/${uuid}.json 2>/dev/null)
    if [ -z "$cred_file" ]; then
        print_color "$RED" "未找到凭据文件，请检查 ~/.cloudflared/"
        return 1
    fi
    cp "$cred_file" "/etc/cloudflared/${tname}.json"
    print_color "$GREEN" "凭据已保存"

    # 添加 DNS 解析（自动）
    print_color "$CYAN" "添加 DNS 记录: $full_domain -> $uuid.cfargotunnel.com"
    if cloudflared tunnel route dns "$tname" "$full_domain"; then
        print_color "$GREEN" "DNS 记录添加成功"
    else
        print_color "$YELLOW" "自动添加 DNS 失败，请手动添加 CNAME：${full_domain} -> ${uuid}.cfargotunnel.com"
    fi

    # 生成 config.yml
    cat > /etc/cloudflared/config.yml <<EOF
tunnel: ${tname}
credentials-file: /etc/cloudflared/${tname}.json
ingress:
  - hostname: ${full_domain}
    service: http://localhost:${LOCAL_PORT}
  - service: http_status:404
EOF

    # 更新配置
    update_config "MODE" "cert"
    update_config "TUNNEL_NAME" "\"$tname\""
    update_config "TUNNEL_UUID" "\"$uuid\""
    update_config "CUSTOM_DOMAIN" "\"$full_domain\""
    update_config "LOCAL_PORT" "$LOCAL_PORT"

    print_color "$GREEN" "========================================"
    print_color "$GREEN" "证书隧道部署完成！"
    print_color "$BLUE" "  域名: $full_domain"
    print_color "$BLUE" "  隧道名称: $tname"
    print_color "$BLUE" "  本地端口: $LOCAL_PORT"
    print_color "$YELLOW" "请确认 DNS 记录已生效，然后启动隧道"
}

#=================== 隧道控制 ===================
start_tunnel() {
    init_config
    if pgrep -f "cloudflared tunnel" &>/dev/null; then
        print_color "$YELLOW" "隧道已在运行"
        return
    fi

    case "$MODE" in
        cert)
            if [ ! -f "/etc/cloudflared/${TUNNEL_NAME}.json" ] || [ ! -f "/etc/cloudflared/config.yml" ]; then
                print_color "$RED" "证书隧道未配置，请先执行「一键部署证书隧道」"
                return 1
            fi
            print_color "$CYAN" "启动证书隧道: $TUNNEL_NAME"
            nohup cloudflared tunnel --config /etc/cloudflared/config.yml run "$TUNNEL_NAME" >> "$LOG_FILE" 2>&1 &
            echo $! > "$PID_FILE"
            sleep 3
            ;;
        token)
            print_color "$CYAN" "启动 Token 隧道..."
            nohup cloudflared tunnel --url http://localhost:${LOCAL_PORT} run --token ${TUNNEL_TOKEN} >> "$LOG_FILE" 2>&1 &
            echo $! > "$PID_FILE"
            sleep 3
            ;;
        quick|*)
            print_color "$CYAN" "启动快速隧道..."
            nohup cloudflared tunnel --url http://localhost:${LOCAL_PORT} --no-autoupdate >> "$LOG_FILE" 2>&1 &
            echo $! > "$PID_FILE"
            sleep 3
            local qdomain=$(grep -o 'https://.*trycloudflare.com' "$LOG_FILE" | head -1)
            [ -n "$qdomain" ] && update_config "TUNNEL_DOMAIN" "$qdomain" && print_color "$GREEN" "域名: $qdomain"
            ;;
    esac

    if pgrep -f "cloudflared tunnel" &>/dev/null; then
        print_color "$GREEN" "隧道启动成功"
    else
        print_color "$RED" "启动失败，查看日志: tail -20 $LOG_FILE"
    fi
}

stop_tunnel() {
    pkill -f "cloudflared tunnel" 2>/dev/null
    rm -f "$PID_FILE"
    print_color "$GREEN" "隧道已停止"
}

restart_tunnel() { stop_tunnel; sleep 1; start_tunnel; }

change_port() {
    init_config
    read -p "新端口 (当前 $LOCAL_PORT): " port
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -le 65535 ]; then
        update_config "LOCAL_PORT" "$port"
        if [ "$MODE" = "cert" ] && [ -f /etc/cloudflared/config.yml ]; then
            sed -i "s|service: http://localhost:.*|service: http://localhost:${port}|" /etc/cloudflared/config.yml
        fi
        print_color "$GREEN" "端口已更新"
        read -p "重启隧道? [y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] && restart_tunnel
    else
        print_color "$RED" "无效端口"
    fi
}

set_token_mode() {
    read -p "隧道 Token: " token
    [ -n "$token" ] && update_config "TUNNEL_TOKEN" "\"$token\""
    read -p "固定域名(可选): " domain
    [ -n "$domain" ] && update_config "FIXED_DOMAIN" "\"$domain\""
    update_config "MODE" "token"
    print_color "$GREEN" "已切换至 Token 模式"
}

show_status() {
    if pgrep -f "cloudflared tunnel" &>/dev/null; then
        print_color "$GREEN" "● 运行中"
        source "$CONF_FILE"
        echo "模式: $MODE"
        case "$MODE" in
            cert) echo "域名: $CUSTOM_DOMAIN" ;;
            token) echo "域名: ${FIXED_DOMAIN:-未设置}" ;;
            quick) echo "域名: ${TUNNEL_DOMAIN:-临时}" ;;
        esac
        echo "端口: $LOCAL_PORT"
    else
        print_color "$RED" "○ 未运行"
    fi
    echo -e "\n${CYAN}最近日志:${NC}"
    tail -n 5 "$LOG_FILE" 2>/dev/null || echo "无日志"
}

#=================== Cron 保活 + 开机自启 ===================
setup_cron() {
    # 每天凌晨 4 点检查，若隧道未运行则启动
    local cmd="pgrep -f 'cloudflared tunnel' || /usr/local/bin/argo cron-start >> /var/log/argo-cron.log 2>&1"
    local cron_line="0 4 * * * $cmd"

    if crontab -l 2>/dev/null | grep -Fq "$cmd"; then
        read -p "保活任务已存在，是否移除? [y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] && (crontab -l 2>/dev/null | grep -Fv "$cmd") | crontab -
    else
        (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
        print_color "$GREEN" "已添加每日保活任务 (凌晨4点)"
    fi
}

setup_autostart() {
    detect_os
    print_color "$CYAN" "设置开机自启..."

    if [ "$OS_ID" = "alpine" ]; then
        # 使用 local.d (需启用 local 服务)
        mkdir -p /etc/local.d
        cat > /etc/local.d/argo-tunnel.start <<EOF
#!/bin/sh
# Argo Tunnel auto start
sleep 5
/usr/local/bin/argo cron-start
EOF
        chmod +x /etc/local.d/argo-tunnel.start
        # 提示启用 local 服务
        if ! rc-service local status &>/dev/null; then
            print_color "$YELLOW" "请执行: rc-update add local && rc-service local start"
        fi
        print_color "$GREEN" "已添加 Alpine 开机自启脚本"
    elif [ "$OS_ID" = "debian" ] || [ "$OS_ID" = "ubuntu" ]; then
        # systemd 服务
        cat > /etc/systemd/system/argo-tunnel.service <<EOF
[Unit]
Description=Argo Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/argo cron-start
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable argo-tunnel
        print_color "$GREEN" "已创建并启用 systemd 服务"
    else
        print_color "$RED" "不支持的系统类型"
    fi
}

# cron 调用的静默启动
cron_start() {
    source "$CONF_FILE" 2>/dev/null
    LOCAL_PORT=${LOCAL_PORT:-8080}
    case "$MODE" in
        cert) nohup cloudflared tunnel --config /etc/cloudflared/config.yml run "$TUNNEL_NAME" >> "$LOG_FILE" 2>&1 & ;;
        token) nohup cloudflared tunnel --url http://localhost:${LOCAL_PORT} run --token ${TUNNEL_TOKEN} >> "$LOG_FILE" 2>&1 & ;;
        *) nohup cloudflared tunnel --url http://localhost:${LOCAL_PORT} --no-autoupdate >> "$LOG_FILE" 2>&1 & ;;
    esac
}

#=================== 安装为系统命令 ===================
install_self() {
    check_root
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    print_color "$GREEN" "已安装系统命令: argo"
    print_color "$GREEN" "现在可以直接在终端输入 'argo' 启动面板。"
}

#=================== 主菜单 ===================
show_menu() {
    clear
    echo -e "${CYAN}============================================${NC}"
    echo -e "${CYAN}     Argo Tunnel 全能面板 v4.0            ${NC}"
    echo -e "${CYAN}============================================${NC}"
    init_config
    . /etc/os-release 2>/dev/null && echo -e "系统: ${PRETTY_NAME:-Alpine}"
    echo -e "转发端口: ${YELLOW}$LOCAL_PORT${NC}"

    if pgrep -f "cloudflared tunnel" &>/dev/null; then
        echo -e "状态: ${GREEN}运行中${NC}"
        case "$MODE" in
            cert) echo -e "域名: ${BLUE}$CUSTOM_DOMAIN${NC}" ;;
            token) echo -e "域名: ${BLUE}${FIXED_DOMAIN:-未设置}${NC}" ;;
            quick) echo -e "域名: ${BLUE}${TUNNEL_DOMAIN:-临时}${NC}" ;;
        esac
    else
        echo -e "状态: ${RED}未运行${NC}"
    fi

    echo -e "${CYAN}--------------------------------------------${NC}"
    echo " 1) 安装 cloudflared"
    echo " 2) 卸载 cloudflared"
    echo " 3) 启动隧道"
    echo " 4) 停止隧道"
    echo " 5) 重启隧道"
    echo " 6) 修改转发端口"
    echo " 7) 证书隧道一键部署 (网页授权+创建+解析)"
    echo " 8) Token 模式配置"
    echo " 9) 查看状态/日志"
    echo "10) 每日保活 Cron"
    echo "11) 设置开机自启"
    echo "12) 安装本脚本为系统命令 (argo)"
    echo " 0) 退出"
    read -p "请输入选项: " choice

    case $choice in
        1) install_cloudflared ;;
        2) uninstall_cloudflared ;;
        3) start_tunnel ;;
        4) stop_tunnel ;;
        5) restart_tunnel ;;
        6) change_port ;;
        7) cert_auto_setup ;;
        8) set_token_mode ;;
        9) show_status ;;
        10) setup_cron ;;
        11) setup_autostart ;;
        12) install_self ;;
        0) exit 0 ;;
        *) print_color "$RED" "无效选项" ;;
    esac
    read -p "按回车键继续..."
    show_menu
}

#=================== 入口 ===================
ensure_bash "$@"

case "$1" in
    install) install_self; exit 0 ;;
    cron-start) cron_start; exit 0 ;;
esac

check_root
init_config

# 检测 cloudflared 是否安装
if ! command -v cloudflared &>/dev/null; then
    print_color "$YELLOW" "cloudflared 未安装，请先安装 (选项1)"
    read -p "是否现在安装? [Y/n]: " yn
    if [[ ! "$yn" =~ ^[Nn]$ ]]; then
        install_cloudflared
    else
        print_color "$YELLOW" "跳过安装，部分功能可能不可用"
    fi
fi

show_menu
