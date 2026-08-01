#!/bin/bash
#====================================================
# Argo Tunnel 全能面板 v3.0
# 模式: 快速隧道 / Token认证 / 证书登录(网页授权)
# 支持: Debian/Ubuntu, Alpine
# 安装为系统命令: ./argo-panel.sh install
#====================================================

CONF_FILE="/etc/argo-tunnel.conf"
LOG_FILE="/var/log/cloudflared.log"
PID_FILE="/var/run/cloudflared.pid"
SCRIPT_PATH="/usr/local/bin/argo"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

print_color() { echo -e "${1}${2}${NC}"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_color "$RED" "请使用 root 权限运行！"
        exit 1
    fi
}

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
        OS_VERSION=$VERSION_ID
    else
        print_color "$RED" "无法识别系统类型！"
        exit 1
    fi
    case "$OS_ID" in
        debian|ubuntu) PKG_MANAGER="apt-get"; INSTALL_CMD="apt-get install -y"; REMOVE_CMD="apt-get remove -y" ;;
        alpine) PKG_MANAGER="apk"; INSTALL_CMD="apk add --no-cache"; REMOVE_CMD="apk del" ;;
        *) print_color "$RED" "暂不支持的系统: $OS_ID"; exit 1 ;;
    esac
}

# 初始化配置文件
init_config() {
    if [ ! -f "$CONF_FILE" ]; then
        mkdir -p "$(dirname "$CONF_FILE")"
        cat > "$CONF_FILE" <<EOF
MODE=quick
LOCAL_PORT=8080
TUNNEL_TOKEN=""
FIXED_DOMAIN=""
TUNNEL_NAME=""
TUNNEL_UUID=""
CUSTOM_DOMAIN=""
EOF
    fi
    source "$CONF_FILE"
}

update_config() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$CONF_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$CONF_FILE"
    else
        echo "${key}=${value}" >> "$CONF_FILE"
    fi
    source "$CONF_FILE"
}

#======================== cloudflared 安装/卸载 ========================
install_cloudflared() {
    detect_os
    print_color "$CYAN" "安装 cloudflared..."
    case "$OS_ID" in
        debian|ubuntu)
            curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | \
                tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
            apt-get update -y >/dev/null
            $INSTALL_CMD cloudflared
            ;;
        alpine)
            ARCH=$(uname -m)
            case "$ARCH" in
                x86_64)  BINARY="cloudflared-linux-amd64" ;;
                aarch64) BINARY="cloudflared-linux-arm64" ;;
                armv7l)  BINARY="cloudflared-linux-arm" ;;
                *) print_color "$RED" "不支持的架构: $ARCH"; return 1 ;;
            esac
            wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/${BINARY}" -O /usr/local/bin/cloudflared
            chmod +x /usr/local/bin/cloudflared
            ;;
    esac
    command -v cloudflared &>/dev/null && print_color "$GREEN" "cloudflared 安装成功！" || print_color "$RED" "安装失败"
}

uninstall_cloudflared() {
    detect_os
    stop_tunnel 2>/dev/null
    case "$OS_ID" in
        debian|ubuntu) $REMOVE_CMD cloudflared; rm -f /etc/apt/sources.list.d/cloudflared.list /usr/share/keyrings/cloudflare-main.gpg ;;
        alpine) rm -f /usr/local/bin/cloudflared ;;
    esac
    print_color "$GREEN" "cloudflared 已卸载。"
}

#======================== 证书模式: 网页授权及创建隧道 ========================
cert_login() {
    print_color "$CYAN" "开始网页授权，请按提示操作..."
    echo "即将打开浏览器授权页面，请在浏览器中登录 Cloudflare 并授权域名。"
    cloudflared tunnel login
    if [ -f ~/.cloudflared/cert.pem ]; then
        mkdir -p /etc/cloudflared
        cp ~/.cloudflared/cert.pem /etc/cloudflared/cert.pem
        print_color "$GREEN" "证书已保存至 /etc/cloudflared/cert.pem"
    else
        print_color "$RED" "授权失败，未找到证书文件。"
        return 1
    fi
}

create_cert_tunnel() {
    if [ ! -f /etc/cloudflared/cert.pem ]; then
        print_color "$RED" "请先进行网页授权（选项 7-1）！"
        return 1
    fi
    read -p "请输入隧道名称 (英文): " tname
    if [ -z "$tname" ]; then
        print_color "$RED" "隧道名称不能为空"
        return 1
    fi
    local uuid
    uuid=$(cloudflared tunnel create "$tname" 2>&1 | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
    if [ -n "$uuid" ]; then
        update_config "TUNNEL_NAME" "\"$tname\""
        update_config "TUNNEL_UUID" "\"$uuid\""
        update_config "MODE" "cert"
        print_color "$GREEN" "隧道 '$tname' 创建成功，UUID: $uuid"
        print_color "$YELLOW" "重要：请为你的自定义域名添加 CNAME 记录:"
        print_color "$BLUE" "  你的域名. CNAME $uuid.cfargotunnel.com"
    else
        print_color "$RED" "隧道创建失败，请检查权限或网络。"
    fi
}

configure_cert_tunnel() {
    source "$CONF_FILE"
    if [ "$MODE" != "cert" ] || [ -z "$TUNNEL_NAME" ]; then
        print_color "$RED" "请先通过「创建证书隧道」建立隧道！"
        return 1
    fi
    read -p "请输入你要使用的自定义域名 (例如 app.example.com): " domain
    read -p "请输入本地转发端口 (当前: $LOCAL_PORT): " port
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        update_config "LOCAL_PORT" "$port"
    else
        print_color "$YELLOW" "端口未变更，使用 $LOCAL_PORT"
    fi
    if [ -n "$domain" ]; then
        update_config "CUSTOM_DOMAIN" "\"$domain\""
    fi
    # 生成 config.yml
    mkdir -p /etc/cloudflared
    cat > /etc/cloudflared/config.yml <<EOF
tunnel: ${TUNNEL_NAME}
credentials-file: /etc/cloudflared/${TUNNEL_NAME}.json
ingress:
  - hostname: ${CUSTOM_DOMAIN}
    service: http://localhost:${LOCAL_PORT}
  - service: http_status:404
EOF
    print_color "$GREEN" "证书隧道配置已更新！"
    print_color "$YELLOW" "请确保已将 ${CUSTOM_DOMAIN} 的 CNAME 指向 ${TUNNEL_UUID}.cfargotunnel.com"
}

#======================== 隧道控制（统一入口） ========================
start_tunnel() {
    init_config
    if pgrep -f "cloudflared tunnel" > /dev/null; then
        print_color "$YELLOW" "隧道已在运行中。"
        show_status
        return
    fi

    case "$MODE" in
        cert)
            if [ -z "$TUNNEL_NAME" ]; then
                print_color "$RED" "证书隧道未配置，请先完成「证书模式配置」。"
                return 1
            fi
            print_color "$CYAN" "启动证书隧道: $TUNNEL_NAME"
            nohup cloudflared tunnel run "$TUNNEL_NAME" > "$LOG_FILE" 2>&1 &
            echo $! > "$PID_FILE"
            sleep 3
            print_color "$GREEN" "隧道已启动，域名: ${CUSTOM_DOMAIN:-未设置}"
            ;;
        token)
            print_color "$CYAN" "启动 Token 隧道，转发端口: $LOCAL_PORT"
            nohup cloudflared tunnel --url http://localhost:${LOCAL_PORT} run --token ${TUNNEL_TOKEN} > "$LOG_FILE" 2>&1 &
            echo $! > "$PID_FILE"
            sleep 5
            print_color "$GREEN" "Token 隧道已启动"
            [ -n "$FIXED_DOMAIN" ] && print_color "$BLUE" "固定域名: $FIXED_DOMAIN"
            ;;
        quick|*)
            print_color "$CYAN" "启动快速隧道，转发端口: $LOCAL_PORT"
            nohup cloudflared tunnel --url http://localhost:${LOCAL_PORT} --no-autoupdate > "$LOG_FILE" 2>&1 &
            echo $! > "$PID_FILE"
            sleep 5
            DOMAIN=$(grep -o 'https://.*trycloudflare.com' "$LOG_FILE" | head -1)
            if [ -n "$DOMAIN" ]; then
                update_config "TUNNEL_DOMAIN" "$DOMAIN"
                print_color "$GREEN" "快速隧道: $DOMAIN"
            fi
            ;;
    esac
}

stop_tunnel() {
    if pgrep -f "cloudflared tunnel" > /dev/null; then
        pkill -f "cloudflared tunnel"
        rm -f "$PID_FILE"
        print_color "$GREEN" "隧道已停止。"
    else
        print_color "$YELLOW" "隧道未运行。"
    fi
}

restart_tunnel() { stop_tunnel; sleep 1; start_tunnel; }

change_port() {
    init_config
    read -p "新本地端口 (当前 $LOCAL_PORT): " new_port
    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
        update_config "LOCAL_PORT" "$new_port"
        if [ "$MODE" = "cert" ]; then
            # 更新 config.yml 中的端口
            sed -i "s|service: http://localhost:.*|service: http://localhost:${LOCAL_PORT}|" /etc/cloudflared/config.yml
        fi
        print_color "$GREEN" "端口已更新，重启后生效。"
        read -p "立即重启隧道? [y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] && restart_tunnel
    else
        print_color "$RED" "无效端口。"
    fi
}

#======================== Token 模式设置 ========================
set_token_mode() {
    init_config
    echo -e "${CYAN}==== Token 命名隧道配置 ====${NC}"
    read -p "输入隧道 Token (回车保持原值): " token
    [ -n "$token" ] && update_config "TUNNEL_TOKEN" "\"$token\""
    read -p "固定域名 (仅面板显示): " domain
    [ -n "$domain" ] && update_config "FIXED_DOMAIN" "\"$domain\""
    update_config "MODE" "token"
    print_color "$GREEN" "已切换至 Token 模式。"
}

#======================== 状态与日志 ========================
show_status() {
    if pgrep -f "cloudflared tunnel" > /dev/null; then
        PID=$(pgrep -f "cloudflared tunnel" | head -1)
        print_color "$GREEN" "隧道运行中 (PID: $PID)"
        source "$CONF_FILE"
        print_color "$BLUE" "模式: $MODE"
        case "$MODE" in
            cert) print_color "$BLUE" "证书隧道: $TUNNEL_NAME ($CUSTOM_DOMAIN)";;
            token) print_color "$BLUE" "Token 隧道: ${FIXED_DOMAIN:-未命名}";;
            quick) print_color "$BLUE" "快速隧道: ${TUNNEL_DOMAIN:-临时域名}";;
        esac
        print_color "$BLUE" "转发端口: $LOCAL_PORT"
        echo -e "\n${CYAN}最近日志:${NC}"
        tail -n 5 "$LOG_FILE" 2>/dev/null || echo "无日志文件"
    else
        print_color "$RED" "隧道未运行"
    fi
}

#======================== Cron 保活 ========================
setup_cron() {
    CRON_CMD="pgrep -f 'cloudflared tunnel' || /usr/local/bin/argo cron-start >> /var/log/argo-cron.log 2>&1"
    CRON_LINE="*/1 * * * * $CRON_CMD"
    if crontab -l 2>/dev/null | grep -Fq "$CRON_CMD"; then
        read -p "保活已存在，移除? [y/N]: " rm_cron
        [[ "$rm_cron" =~ ^[Yy]$ ]] && crontab -l 2>/dev/null | grep -Fv "$CRON_CMD" | crontab -
    else
        (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
        print_color "$GREEN" "已添加每分钟保活。"
    fi
}

cron_start() {
    source "$CONF_FILE" 2>/dev/null
    LOCAL_PORT=${LOCAL_PORT:-8080}
    case "$MODE" in
        cert) nohup cloudflared tunnel run "$TUNNEL_NAME" >> "$LOG_FILE" 2>&1 & ;;
        token) nohup cloudflared tunnel --url http://localhost:${LOCAL_PORT} run --token ${TUNNEL_TOKEN} >> "$LOG_FILE" 2>&1 & ;;
        quick|*) nohup cloudflared tunnel --url http://localhost:${LOCAL_PORT} --no-autoupdate >> "$LOG_FILE" 2>&1 & ;;
    esac
}

#======================== 安装自身为系统命令 ========================
install_self() {
    check_root
    [ -f "$SCRIPT_PATH" ] && print_color "$YELLOW" "覆盖已存在的 /usr/local/bin/argo"
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    print_color "$GREEN" "安装完成！现在可直接输入 argo 运行。"
    exit 0
}

#======================== 主菜单 ========================
show_menu() {
    clear
    echo -e "${CYAN}============================================${NC}"
    echo -e "${CYAN}     Argo Tunnel 全能面板 v3.0            ${NC}"
    echo -e "${CYAN}============================================${NC}"
    init_config
    . /etc/os-release 2>/dev/null && echo -e "${GREEN}系统: $PRETTY_NAME${NC}"
    echo -e "${GREEN}转发端口: ${YELLOW}$LOCAL_PORT${NC}"

    if pgrep -f "cloudflared tunnel" > /dev/null; then
        echo -e "${GREEN}隧道状态: ${YELLOW}运行中${NC}"
        case "$MODE" in
            cert) echo -e "${GREEN}模式: ${CYAN}证书隧道 ${TUNNEL_NAME}${NC}"; echo -e "${GREEN}域名: ${BLUE}$CUSTOM_DOMAIN${NC}";;
            token) echo -e "${GREEN}模式: ${CYAN}Token 隧道${NC}"; [ -n "$FIXED_DOMAIN" ] && echo -e "${GREEN}域名: ${BLUE}$FIXED_DOMAIN${NC}";;
            quick) [ -n "$TUNNEL_DOMAIN" ] && echo -e "${GREEN}域名: ${BLUE}$TUNNEL_DOMAIN${NC}";;
        esac
    else
        echo -e "${GREEN}隧道状态: ${RED}未运行${NC}"
    fi

    echo -e "${CYAN}--------------------------------------------${NC}"
    echo -e " 1. 安装 cloudflared"
    echo -e " 2. 卸载 cloudflared"
    echo -e " 3. 启动隧道"
    echo -e " 4. 停止隧道"
    echo -e " 5. 重启隧道"
    echo -e " 6. 修改转发端口"
    echo -e " 7. 证书模式配置 (网页授权/创建隧道/设置域名)"
    echo -e " 8. Token 模式配置"
    echo -e " 9. 查看状态/日志"
    echo -e "10. Cron 保活设置"
    echo -e "11. 安装本脚本为系统命令 (argo)"
    echo -e " 0. 退出"
    echo -e "${CYAN}============================================${NC}"
    read -p "请输入选项 [0-11]: " choice

    case $choice in
        1) install_cloudflared ;;
        2) uninstall_cloudflared ;;
        3) start_tunnel ;;
        4) stop_tunnel ;;
        5) restart_tunnel ;;
        6) change_port ;;
        7)
            echo -e "${CYAN}==== 证书模式子菜单 ====${NC}"
            echo "7-1) 网页授权获取证书"
            echo "7-2) 创建证书隧道"
            echo "7-3) 设置域名并生成配置"
            echo "7-4) 返回主菜单"
            read -p "选择: " sub
            case $sub in
                1) cert_login ;;
                2) create_cert_tunnel ;;
                3) configure_cert_tunnel ;;
                *) ;;
            esac
            ;;
        8) set_token_mode ;;
        9) show_status ;;
        10) setup_cron ;;
        11) install_self ;;
        0) exit 0 ;;
        *) print_color "$RED" "无效选项" ;;
    esac
    read -p "按回车键继续..."
    show_menu
}

#======================== 入口 ========================
case "$1" in
    install) install_self ;;
    cron-start) cron_start; exit 0 ;;
esac

check_root
init_config

if ! command -v cloudflared &>/dev/null; then
    print_color "$YELLOW" "未检测到 cloudflared，请先安装 (选项1)"
    read -p "是否现在安装? [Y/n]: " yn
    [[ ! "$yn" =~ ^[Nn]$ ]] && install_cloudflared
fi

show_menu
