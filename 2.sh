#!/usr/bin/env bash
# Argo Tunnel 管理面板脚本（带 token 粘贴提取支持）
# - 交互式面板：启动/停止/重启/状态/改端口/日志/cron 保活/安装卸载 cloudflared / 检测系统类型
# - 支持从 cloudflared 给出的粘贴命令中提取 --token 并保存到配置，启动时可选使用 token 授权
# 注意：需要 bash、curl/wget（下载安装二进制时）、以及 cloudflared（可用面板安装）
set -e

# ---------------------------
# 基本环境与路径（自动选择 root / user）
# ---------------------------
SCRIPT_PATH="$(readlink -f "$0")"
USER_UID="$(id -u)"
if [ "$USER_UID" -eq 0 ]; then
  CONFIG_FILE="/etc/argo-panel.conf"
  LOG_FILE="/var/log/argo-panel.log"
  PID_FILE="/var/run/argo-panel.pid"
  CRON_FILE="/etc/cron.d/argo-panel"
  CRON_IS_ROOT=1
else
  CONFIG_FILE="$HOME/.argo-panel.conf"
  LOG_FILE="$HOME/argo-panel.log"
  PID_FILE="$HOME/argo-panel.pid"
  CRON_FILE="$HOME/.argo-panel.cron"
  CRON_IS_ROOT=0
fi

DEFAULT_PORT=8080

# ---------------------------
# 配置读取/写入
# ---------------------------
load_config() {
  PORT="$DEFAULT_PORT"
  TOKEN=""
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
  if [ -z "$PORT" ]; then
    PORT="$DEFAULT_PORT"
  fi
}
save_config() {
  mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
  cat > "$CONFIG_FILE" <<EOF
# argo-panel config (auto-generated)
PORT="$PORT"
TOKEN="$TOKEN"
EOF
}

# ---------------------------
# 辅助函数
# ---------------------------
echo_err() { printf "%s\n" "$*" >&2; }
is_port_valid() {
  case "$1" in
    ''|*[!0-9]*)
      return 1;;
    *)
      if [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null; then
        return 0
      else
        return 1
      fi;;
  esac
}

ensure_cloudflared() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    echo_err "未检测到 cloudflared。可在面板选择安装（需要网络与必要权限）。"
    return 1
  fi
  return 0
}

# ---------------------------
# OS / package manager 检测
# ---------------------------
detect_os() {
  OS=""
  OS_ID=""
  OS_NAME=""
  PM=""
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_NAME="${NAME:-}"
  fi
  UNAME="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$OS_ID" in
    alpine)
      OS="alpine"
      PM="apk"
      ;;
    ubuntu|debian)
      OS="$OS_ID"
      PM="apt"
      ;;
    centos|rhel|rocky|almalinux)
      OS="$OS_ID"
      if command -v dnf >/dev/null 2>&1; then PM="dnf"; else PM="yum"; fi
      ;;
    fedora)
      OS="fedora"
      PM="dnf"
      ;;
    arch)
      OS="arch"
      PM="pacman"
      ;;
    *)
      if command -v apk >/dev/null 2>&1; then PM="apk"; OS="alpine"; fi
      if command -v apt-get >/dev/null 2>&1; then PM="apt"; OS="${OS:-debian/ubuntu}"; fi
      if command -v dnf >/dev/null 2>&1; then PM="dnf"; OS="${OS:-rhel/fedora}"; fi
      if command -v yum >/dev/null 2>&1; then PM="yum"; OS="${OS:-rhel}"; fi
      if command -v pacman >/dev/null 2>&1; then PM="pacman"; OS="${OS:-arch}"; fi
      ;;
  esac
  DETECTED_OS="$OS"
  DETECTED_PM="$PM"
  DETECTED_OS_ID="$OS_ID"
}

print_detected() {
  detect_os
  echo "检测到系统: ${DETECTED_OS_ID:-$DETECTED_OS} （$DETECTED_OS），包管理器: ${DETECTED_PM:-unknown}"
}

# ---------------------------
# cloudflared 安装/卸载（尽量兼容 Debian/Ubuntu/Alpine + 通用二进制回退）
# ---------------------------
_arch_map() {
  local u
  u="$(uname -m)"
  case "$u" in
    x86_64|amd64) echo "amd64";;
    aarch64|arm64) echo "arm64";;
    armv7l|armv7) echo "arm";;
    i386|i686) echo "386";;
    *) echo "amd64";;
  esac
}

_download_and_place_binary() {
  local arch="$1"
  local target_dir="$2"
  local tmpfile
  tmpfile="$(mktemp)"
  local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  echo "从 $url 下载 cloudflared ..."
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL -o "$tmpfile" "$url"; then
      echo_err "下载失败（curl）。"
      rm -f "$tmpfile" || true
      return 1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -qO "$tmpfile" "$url"; then
      echo_err "下载失败（wget）。"
      rm -f "$tmpfile" || true
      return 1
    fi
  else
    echo_err "系统缺少 curl/wget，无法下载二进制。"
    rm -f "$tmpfile" || true
    return 1
  fi

  mkdir -p "$target_dir" 2>/dev/null || true
  chmod +x "$tmpfile" || true
  mv "$tmpfile" "$target_dir/cloudflared"
  chmod +x "$target_dir/cloudflared" || true
  echo "已安装到 $target_dir/cloudflared"
  return 0
}

install_cloudflared() {
  detect_os
  if command -v cloudflared >/dev/null 2>&1; then
    echo "检测到已安装 cloudflared: $(command -v cloudflared) ($(cloudflared --version 2>/dev/null || echo 'unknown'))"
    read -r -p "是否重新安装/覆盖？(y/N): " yn
    case "$yn" in
      [Yy]*) ;;
      *) echo "取消安装。"; return 0;;
    esac
  fi

  local ARCH
  ARCH="$(_arch_map)"
  if [ "$DETECTED_PM" = "apt" ] && [ "$USER_UID" -eq 0 ]; then
    echo "在 Debian/Ubuntu 系统上（root），尝试通过 apt 安装 cloudflared（添加官方仓库）..."
    set +e
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y curl gnupg lsb-release >/dev/null 2>&1 || true
    if curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg >/tmp/cloudflare-main.gpg 2>/dev/null; then
      mkdir -p /usr/share/keyrings 2>/dev/null || true
      cat /tmp/cloudflare-main.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg 2>/dev/null || cat /tmp/cloudflare-main.gpg > /usr/share/keyrings/cloudflare-main.gpg
      rm -f /tmp/cloudflare-main.gpg
    fi
    if command -v lsb_release >/dev/null 2>&1; then
      CODENAME=$(lsb_release -cs 2>/dev/null || echo "")
    else
      . /etc/os-release
      CODENAME="${VERSION_CODENAME:-${VERSION_ID:-stable}}"
    fi
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/ ${CODENAME} main" > /etc/apt/sources.list.d/cloudflare-main.list
    apt-get update -y
    if apt-get install -y cloudflared; then
      echo "cloudflared 安装成功（apt）。"
      set -e
      return 0
    else
      echo_err "通过 apt 安装失败，回退为二进制下载安装。"
    fi
    set -e
  fi

  if [ "$USER_UID" -eq 0 ]; then
    TARGET_DIR="/usr/local/bin"
  else
    TARGET_DIR="$HOME/.local/bin"
    mkdir -p "$TARGET_DIR" 2>/dev/null || true
    case ":$PATH:" in
      *":$HOME/.local/bin:"*) ;;
      *) PATH="$HOME/.local/bin:$PATH";;
    esac
  fi

  if _download_and_place_binary "$ARCH" "$TARGET_DIR"; then
    echo "验证 cloudflared 版本："
    "$TARGET_DIR/cloudflared" --version || true
    echo "安装完成。请确保 $TARGET_DIR 在 PATH 中或以绝对路径运行。"
    return 0
  else
    echo_err "二进制安装失败。请手动检查网络或使用发行版的包管理器安装 cloudflared。"
    return 1
  fi
}

uninstall_cloudflared() {
  detect_os
  if ! command -v cloudflared >/dev/null 2>&1; then
    echo "未检测到已安装的 cloudflared（系统中不存在）。检查常见安装位置并尝试移除可能存在的二进制。"
  fi

  if [ "$USER_UID" -eq 0 ] && [ -n "$DETECTED_PM" ]; then
    case "$DETECTED_PM" in
      apt)
        if dpkg -l | grep -q cloudflared; then
          echo "通过 apt 卸载 cloudflared ..."
          apt-get remove -y cloudflared || true
          apt-get purge -y cloudflared || true
          rm -f /etc/apt/sources.list.d/cloudflare-main.list /usr/share/keyrings/cloudflare-main.gpg 2>/dev/null || true
          echo "apt 卸载完成（若存在）。"
          return 0
        fi
        ;;
      dnf|yum)
        if rpm -qa | grep -q cloudflared; then
          echo "通过 $DETECTED_PM 卸载 cloudflared ..."
          $DETECTED_PM remove -y cloudflared || true
          echo "$DETECTED_PM 卸载完成（若存在）。"
          return 0
        fi
        ;;
    esac
  fi

  REMOVED=0
  for p in /usr/local/bin/cloudflared /usr/bin/cloudflared "$HOME/.local/bin/cloudflared" /bin/cloudflared; do
    if [ -f "$p" ]; then
      if [ "$USER_UID" -ne 0 ] && [[ "$p" = /usr* ]]; then
        echo "需要 root 权限才能删除 $p（跳过）"
      else
        rm -f "$p" 2>/dev/null || true
        echo "已删除 $p"
        REMOVED=1
      fi
    fi
  done
  if [ "$REMOVED" -eq 0 ]; then
    echo "未找到可移除的 cloudflared 二进制（或需 root 权限）。"
  fi
  return 0
}

# ---------------------------
# Token 提取功能
# ---------------------------
# 从任意文本（通常为 cloudflared 提示的命令）中提取 token
# 支持形式：--token=ABC --token ABC token=ABC "token: ABC" 等常见形式
extract_token_from_text() {
  local text="$1"
  local tok=""
  # 优先匹配 --token=VALUE 或 --token VALUE
  tok="$(printf "%s" "$text" | grep -Eo -- '--token[= ]+[A-Za-z0-9._:-]+' | head -n1 | sed -E 's/--token[= ]+//g')"
  if [ -z "$tok" ]; then
    # 匹配 token=VALUE
    tok="$(printf "%s" "$text" | grep -Eo -- 'token[=][A-Za-z0-9._:-]+' | head -n1 | sed -E 's/token=//g')"
  fi
  if [ -z "$tok" ]; then
    # 匹配 "Token: VALUE" 或 "token: VALUE"
    tok="$(printf "%s" "$text" | grep -Eio -- 'token[: ][ ]*[A-Za-z0-9._:-]+' | head -n1 | sed -E 's/^[Tt]oken[: ]*//g' | tr -d '\r\n')"
  fi
  # 最后尝试从双引号或单引号内匹配任意可能的 token-like 片段，这可以捕获 cloudflared docs 给出的示例
  if [ -z "$tok" ]; then
    tok="$(printf "%s" "$text" | sed -nE "s/.*['\"]([A-Za-z0-9._:-]{8,})['\"].*/\\1/p" | head -n1 || true)"
  fi
  printf "%s" "$tok"
}

prompt_paste_and_extract_token() {
  echo "请粘贴 cloudflared 给你的命令或文本（一行），脚本会尝试从中提取 token。输入空行取消。"
  echo -n "粘贴并回车: "
  IFS= read -r PASTED || true
  if [ -z "$PASTED" ]; then
    echo "已取消。"
    return 1
  fi
  FOUND="$(extract_token_from_text "$PASTED")"
  if [ -n "$FOUND" ]; then
    echo "提取到 token: $FOUND"
    read -r -p "是否保存为当前 token 并重启 tunnel？(y/N): " yn
    case "$yn" in
      [Yy]*)
        TOKEN="$FOUND"
        save_config
        echo "已保存 token 到配置：$CONFIG_FILE，正在重启 tunnel..."
        stop_tunnel
        sleep 1
        start_tunnel
        ;;
      *)
        TOKEN="$FOUND"
        echo "已提取但未保存（如需保存请在面板里使用编辑 token 选项）。"
        ;;
    esac
  else
    echo "未能从粘贴内容中提取到 token，请确认命令中包含 --token <TOKEN> 或 token=<TOKEN> 等信息，或手动在面板中输入 token。"
    return 1
  fi
  return 0
}

# ---------------------------
# Tunnel 管理（start/stop/status），若有 TOKEN 则使用 token 模式
# ---------------------------
start_tunnel() {
  ensure_cloudflared || return 1
  load_config

  if [ -f "$PID_FILE" ]; then
    PID="$(cat "$PID_FILE" 2>/dev/null || echo "")"
    if [ -n "$PID" ] && ps -p "$PID" >/dev/null 2>&1; then
      echo "Tunnel 已在运行 (PID $PID)。"
      return 0
    fi
  fi

  # 构建启动命令：若 TOKEN 存在则带上 --token 参数
  if [ -n "$TOKEN" ]; then
    CMD_ARGS=(tunnel --url "http://127.0.0.1:$PORT" --token "$TOKEN" --no-autoupdate)
    echo "使用 token 启动 cloudflared（将使用配置中的 token）"
  else
    CMD_ARGS=(tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate)
    echo "使用默认启动方式（若首次运行可能会要求在浏览器中授权）"
  fi

  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  echo "启动 cloudflared：cloudflared ${CMD_ARGS[*]}"
  nohup cloudflared "${CMD_ARGS[@]}" >> "$LOG_FILE" 2>&1 &
  NEWPID=$!
  echo "$NEWPID" > "$PID_FILE"
  sleep 1
  echo "已启动（PID $NEWPID），日志：$LOG_FILE"
  sleep 0.5
  show_public_url_from_log
  return 0
}

stop_tunnel() {
  if [ -f "$PID_FILE" ]; then
    PID="$(cat "$PID_FILE" 2>/dev/null || echo "")"
    if [ -n "$PID" ] && ps -p "$PID" >/dev/null 2>&1; then
      echo "停止 PID $PID ..."
      kill "$PID" >/dev/null 2>&1 || true
      sleep 1
      if ps -p "$PID" >/dev/null 2>&1; then
        echo "进程仍存，尝试强制杀死..."
        kill -9 "$PID" >/dev/null 2>&1 || true
      fi
    fi
    rm -f "$PID_FILE" 2>/dev/null || true
  else
    PIDS=$(ps aux | grep -v grep | grep 'cloudflared' | awk '{print $2}')
    if [ -n "$PIDS" ]; then
      echo "检测到 cloudflared 进程 ($PIDS)，尝试停止..."
      for p in $PIDS; do kill "$p" >/dev/null 2>&1 || true; done
    else
      echo "未检测到运行中的 tunnel。"
    fi
  fi
  echo "已停止。"
}

status_tunnel() {
  if [ -f "$PID_FILE" ]; then
    PID="$(cat "$PID_FILE" 2>/dev/null || echo "")"
    if [ -n "$PID" ] && ps -p "$PID" >/dev/null 2>&1; then
      echo "Tunnel 正在运行，PID: $PID"
      echo "日志 (尾部)："
      tail -n 20 "$LOG_FILE" 2>/dev/null || true
      show_public_url_from_log
      return 0
    fi
  fi
  PIDS=$(ps aux | grep -v grep | grep 'cloudflared' | awk '{print $2}')
  if [ -n "$PIDS" ]; then
    echo "检测到 cloudflared 进程（但没有 PID 文件）: $PIDS"
    tail -n 20 "$LOG_FILE" 2>/dev/null || true
    show_public_url_from_log
    return 0
  fi
  echo "Tunnel 未运行。"
  tail -n 20 "$LOG_FILE" 2>/dev/null || true
  return 1
}

show_public_url_from_log() {
  if [ -f "$LOG_FILE" ]; then
    URL="$(grep -Eo 'https?://[^ ]+' "$LOG_FILE" | tail -n 10 | tac | awk '!seen[$0]++' | head -n1 || true)"
    if [ -n "$URL" ]; then
      echo "公开访问地址 (从日志解析)：$URL"
    else
      echo "未从日志中解析到公开地址，请查看日志：$LOG_FILE"
    fi
  else
    echo "日志文件不存在：$LOG_FILE"
  fi
}

show_logs() {
  echo "=== 最近 200 行日志：$LOG_FILE ==="
  tail -n 200 "$LOG_FILE" 2>/dev/null || echo "(日志文件不存在)"
}

# ---------------------------
# Cron 保活
# ---------------------------
setup_cron() {
  load_config
  if [ "$CRON_IS_ROOT" -eq 1 ]; then
    cat > "$CRON_FILE" <<EOF
# Automatically generated by argo-panel
* * * * * root $SCRIPT_PATH --ensure-running >/dev/null 2>&1
EOF
    echo "已写入 $CRON_FILE"
  else
    (crontab -l 2>/dev/null | grep -v -F "$SCRIPT_PATH --ensure-running" || true; echo "* * * * * /bin/bash $SCRIPT_PATH --ensure-running >/dev/null 2>&1") | crontab -
    echo "已安装用户 crontab 条目。"
  fi
}

remove_cron() {
  if [ "$CRON_IS_ROOT" -eq 1 ]; then
    if [ -f "$CRON_FILE" ]; then
      rm -f "$CRON_FILE"
      echo "已删除 $CRON_FILE"
    else
      echo "未找到 $CRON_FILE"
    fi
  else
    crontab -l 2>/dev/null | grep -v -F "$SCRIPT_PATH --ensure-running" | crontab -
    echo "已从用户 crontab 中移除保活条目（若存在）。"
  fi
}

ensure_running_entrypoint() {
  load_config
  if ! command -v cloudflared >/dev/null 2>&1; then exit 0; fi
  if [ -f "$PID_FILE" ]; then
    PID="$(cat "$PID_FILE" 2>/dev/null || echo "")"
    if [ -n "$PID" ] && ps -p "$PID" >/dev/null 2>&1; then exit 0; fi
  fi
  if ps aux | grep -v grep | grep 'cloudflared' >/dev/null 2>&1; then exit 0; fi
  start_tunnel >/dev/null 2>&1 || true
  exit 0
}

# ---------------------------
# 面板与用户交互
# ---------------------------
print_menu() {
  echo "===================================="
  echo "  Argo Tunnel 管理面板"
  echo "  配置文件：$CONFIG_FILE"
  echo "  日志：$LOG_FILE"
  echo "------------------------------------"
  load_config
  echo "  当前转发端口: $PORT"
  echo "  token: ${TOKEN:+(已设置)}"
  echo "------------------------------------"
  echo "  1) 启动 Tunnel"
  echo "  2) 停止 Tunnel"
  echo "  3) 重启 Tunnel"
  echo "  4) 查看状态"
  echo "  5) 修改转发端口"
  echo "  6) 查看日志 (tail)"
  echo "  7) 安装/启用 Cron 保活 (每分钟检测)"
  echo "  8) 卸载/移除 Cron 保活"
  echo "  9) 编辑 token / 高级配置"
  echo "  a) 显示上次启动日志中解析到的公开地址"
  echo "  i) 检测系统类型 & 包管理器"
  echo "  j) 安装 cloudflared"
  echo "  k) 卸载 cloudflared"
  echo "  l) 粘贴 cloudflared 给出的命令并自动提取 token"
  echo "  q) 退出"
  echo "===================================="
  echo -n "请选择: "
}

prompt_modify_port() {
  echo -n "请输入新的本地转发端口 (当前: $PORT): "
  read -r NEWPORT
  if ! is_port_valid "$NEWPORT"; then
    echo "端口无效。请填写 1-65535 的整数。"
    return 1
  fi
  PORT="$NEWPORT"
  save_config
  echo "端口已保存为 $PORT，正在重启 tunnel..."
  stop_tunnel
  sleep 1
  start_tunnel
}

prompt_edit_token() {
  echo "注意：是否需要 token 或已创建的 tunnel 取决于你的 cloudflared 使用方式。"
  echo -n "请输入 token（留空表示不使用 token）："
  read -r INPUT_TOKEN
  TOKEN="$INPUT_TOKEN"
  save_config
  echo "token 已保存（若留空则移除）。如果需要用 token 启动，请在面板里选择启动。"
}

# ---------------------------
# 命令行解析（支持 cron 调用）
# ---------------------------
case "$1" in
  --ensure-running)
    ensure_running_entrypoint
    exit 0
    ;;
  --start)
    start_tunnel
    exit $?
    ;;
  --stop)
    stop_tunnel
    exit $?
    ;;
  --status)
    status_tunnel
    exit $?
    ;;
  --setup-cron)
    setup_cron
    exit 0
    ;;
  --remove-cron)
    remove_cron
    exit 0
    ;;
esac

# ---------------------------
# 运行面板循环
# ---------------------------
load_config
save_config
while true; do
  print_menu
  read -r CHOICE
  case "$CHOICE" in
    1) start_tunnel ;;
    2) stop_tunnel ;;
    3) stop_tunnel; sleep 1; start_tunnel ;;
    4) status_tunnel ;;
    5) prompt_modify_port ;;
    6) show_logs ;;
    7) setup_cron ;;
    8) remove_cron ;;
    9) prompt_edit_token ;;
    a|A) show_public_url_from_log ;;
    i|I) print_detected ;;
    j|J) install_cloudflared ;;
    k|K) uninstall_cloudflared ;;
    l|L) prompt_paste_and_extract_token ;;
    q|Q) echo "退出。"; exit 0 ;;
    *) echo "未识别选项。" ;;
  esac
  echo
  sleep 0.2
done
