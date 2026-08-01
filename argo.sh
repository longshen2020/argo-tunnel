#!/usr/bin/env bash

#########################################
# Argo Tunnel Panel
# Version: 1.0
#########################################

VERSION="1.0"

BASE_DIR="/etc/argo-panel"
CFG="${BASE_DIR}/config.conf"
PID_FILE="${BASE_DIR}/argo.pid"
LOG_FILE="${BASE_DIR}/argo.log"
DOMAIN_FILE="${BASE_DIR}/domain"
CRON_FILE="${BASE_DIR}/crond.sh"

CF_BIN="${BASE_DIR}/cloudflared"

mkdir -p ${BASE_DIR}

#########################################
# 配置初始化
#########################################

init_config(){

if [ ! -f "$CFG" ];then

cat > $CFG <<EOF
MODE=temp
FORWARD=127.0.0.1:8080
TOKEN=
DOMAIN=
EOF

fi

}

#########################################
# 读取配置
#########################################

load_config(){

source $CFG

}

#########################################
# 保存配置
#########################################

save_config(){

cat > $CFG <<EOF
MODE=${MODE}
FORWARD=${FORWARD}
TOKEN=${TOKEN}
DOMAIN=${DOMAIN}
EOF

}

#########################################
# 系统检测
#########################################

detect_os(){

if [ -f /etc/alpine-release ];then

OS="alpine"

elif [ -f /etc/debian_version ];then

OS="debian"

elif [ -f /etc/redhat-release ];then

OS="centos"

else

echo "Unsupported System"

exit 1

fi

}

#########################################
# 架构检测
#########################################

detect_arch(){

ARCH=$(uname -m)

case "$ARCH" in

x86_64)

ARCH=amd64
;;

aarch64)

ARCH=arm64
;;

armv7l)

ARCH=arm
;;

i386|i686)

ARCH=386
;;

*)

echo "Unsupported Arch"

exit 1

;;

esac

}

#########################################
# 下载cloudflared
#########################################

download_cf(){

if [ -f "$CF_BIN" ];then

return

fi

detect_arch

URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"

echo "Downloading cloudflared..."

if command -v wget >/dev/null 2>&1;then

wget -O ${CF_BIN} ${URL}

elif command -v curl >/dev/null 2>&1;then

curl -L ${URL} -o ${CF_BIN}

else

echo "Need curl or wget"

exit 1

fi

chmod +x ${CF_BIN}

}

#########################################
# PID
#########################################

is_running(){

if [ ! -f "$PID_FILE" ];then

return 1

fi

PID=$(cat "$PID_FILE")

kill -0 "$PID" >/dev/null 2>&1

}

#########################################
# 停止
#########################################

stop_tunnel(){

if is_running

then

kill $(cat $PID_FILE)

rm -f $PID_FILE

echo "Stopped."

else

echo "Tunnel not running."

fi

}

#########################################
# 获取域名
#########################################

update_domain(){

sleep 3

DOMAIN=$(grep -oE "https://[-a-zA-Z0-9.]+trycloudflare.com" $LOG_FILE | head -n1)

DOMAIN=${DOMAIN#https://}

echo "$DOMAIN" > $DOMAIN_FILE

save_config

}

#########################################
# 状态
#########################################

status(){

load_config

echo ""

echo "=========="

echo "Mode      : $MODE"

echo "Forward   : $FORWARD"

echo "Domain    : $DOMAIN"

if is_running

then

echo "Status    : Running"

else

echo "Status    : Stopped"

fi

echo "=========="

}

#########################################
# 修改端口
#########################################

change_port(){

load_config

echo

echo "Current:"

echo "$FORWARD"

echo

read -p "New Forward (127.0.0.1:8080): " NEW

[ -z "$NEW" ] && return

FORWARD=$NEW

save_config

echo

echo "Saved."

echo

}

#########################################
# 查看日志
#########################################

show_log(){

tail -30 $LOG_FILE

}

#########################################
# 删除
#########################################

remove_all(){

stop_tunnel

rm -rf ${BASE_DIR}

echo "Removed."

}

#########################################
# Header
#########################################

header(){

echo

echo "Argo Tunnel Panel"

echo "Version ${VERSION}"

echo

}

#########################################
# Menu
#########################################

menu(){

header

echo "1. Install cloudflared"

echo "2. Start Temp Tunnel"

echo "3. Start Token Tunnel"

echo "4. Stop Tunnel"

echo "5. Restart Tunnel"

echo "6. Change Forward Port"

echo "7. Status"

echo "8. Log"

echo "9. Install Cron"

echo "10.Remove"

echo "0.Exit"

echo

read -p "Select: " NUM

case "$NUM" in

1)

download_cf
;;

2)

start_temp
;;

3)

start_token
;;

4)

stop_tunnel
;;

5)

restart_tunnel
;;

6)

change_port
;;

7)

status
;;

8)

show_log
;;

9)

install_cron
;;

10)

remove_all
;;

0)

exit
;;

*)

echo "Invalid"

;;

esac

}

#########################################
# Main
#########################################

init_config

while true

do

menu

echo

read -p "Enter Continue..."

done

#########################################
# 启动临时 Tunnel
#########################################

start_temp(){

load_config

download_cf

if is_running
then

echo "Tunnel already running."

return

fi


echo "Starting temporary tunnel..."

rm -f $LOG_FILE


nohup $CF_BIN tunnel \
--no-autoupdate \
--url http://${FORWARD} \
>>$LOG_FILE 2>&1 &


PID=$!

echo $PID > $PID_FILE


sleep 5


update_domain


echo

echo "Tunnel Started."

echo

if [ -f $DOMAIN_FILE ]
then

echo "Domain:"
cat $DOMAIN_FILE

fi

}



#########################################
# Token Tunnel
#########################################

start_token(){

load_config

download_cf


if [ -z "$TOKEN" ]
then

echo

read -p "Input Tunnel Token: " TOKEN

if [ -z "$TOKEN" ]
then

echo "Token empty."

return

fi

save_config

fi


if is_running
then

echo "Tunnel already running."

return

fi


echo "Starting token tunnel..."


rm -f $LOG_FILE


nohup $CF_BIN tunnel run \
--token ${TOKEN} \
>>$LOG_FILE 2>&1 &


PID=$!

echo $PID > $PID_FILE


sleep 5


echo

echo "Token Tunnel Started."

}



#########################################
# 重启 Tunnel
#########################################

restart_tunnel(){

load_config


echo "Restarting..."


stop_tunnel


sleep 2


case "$MODE" in


temp)

start_temp

;;


token)

start_token

;;


*)

echo "Unknown mode"

;;

esac


}



#########################################
# 设置模式
#########################################

set_mode(){


echo

echo "Current mode: $MODE"

echo

echo "1. Temporary"

echo "2. Token"

read -p "Choose: " M


case "$M" in


1)

MODE=temp

;;


2)

MODE=token

;;


*)

echo "Invalid"

return

;;

esac


save_config


echo "Mode changed."

}



#########################################
# 修改Token
#########################################

change_token(){


load_config


read -p "New Token: " TOKEN


save_config


echo

echo "Token saved."

}



#########################################
# 显示完整配置
#########################################

show_config(){


load_config


echo

echo "---------"

echo "MODE    : $MODE"

echo "FORWARD : $FORWARD"

echo "TOKEN   : ${TOKEN:0:20}..."

echo "DOMAIN  : $DOMAIN"

echo "---------"

}


#########################################
# 清理日志
#########################################

clear_log(){

echo "" > $LOG_FILE

echo "Log cleared."

}

#########################################
# Cron 保活脚本
#########################################

create_cron_script(){

cat > $CRON_FILE <<'EOF'
#!/bin/sh

BASE_DIR="/etc/argo-panel"

PID_FILE="${BASE_DIR}/argo.pid"

CFG="${BASE_DIR}/config.conf"

PANEL="/usr/local/bin/argo-panel.sh"


if [ ! -f "$CFG" ];then

exit 0

fi


. $CFG


running(){

if [ ! -f "$PID_FILE" ];then

return 1

fi


PID=$(cat $PID_FILE)


kill -0 $PID >/dev/null 2>&1

}


if ! running
then

case "$MODE" in


temp)

nohup ${BASE_DIR}/cloudflared \
tunnel \
--no-autoupdate \
--url http://${FORWARD} \
>>${BASE_DIR}/argo.log 2>&1 &


echo $! > $PID_FILE


;;


token)

nohup ${BASE_DIR}/cloudflared \
tunnel run \
--token ${TOKEN} \
>>${BASE_DIR}/argo.log 2>&1 &


echo $! > $PID_FILE


;;


esac


fi

EOF


chmod +x $CRON_FILE


}



#########################################
# 安装Cron保活
#########################################

install_cron(){


create_cron_script


echo

echo "Installing cron..."


if command -v crontab >/dev/null 2>&1

then


(crontab -l 2>/dev/null | grep -v argo-panel; \
echo "* * * * * ${CRON_FILE}") | crontab -


echo

echo "Cron installed."


else


echo

echo "crontab not found."

echo "Install cron package first."


fi


}



#########################################
# 删除Cron
#########################################

remove_cron(){


if command -v crontab >/dev/null 2>&1

then


crontab -l 2>/dev/null \
| grep -v argo-panel \
| crontab -


fi


rm -f $CRON_FILE


echo "Cron removed."


}



#########################################
# 安装入口命令
#########################################

install_command(){


TARGET="/usr/local/bin/argo-panel"


if [ "$0" != "$TARGET" ]

then

cp "$0" "$TARGET"

chmod +x "$TARGET"


echo

echo "Installed command:"

echo "argo-panel"


fi


}



#########################################
# 检查依赖
#########################################

check_dependency(){


if ! command -v crontab >/dev/null 2>&1

then

echo

echo "Warning: cron unavailable."

fi


}



#########################################
# 更新域名显示
#########################################

show_domain(){


if [ -f "$DOMAIN_FILE" ]

then

echo

echo "Tunnel Domain:"

cat $DOMAIN_FILE


else

echo

echo "No domain found."

fi


}



#########################################
# 运行信息
#########################################

info(){


echo

echo "=========="

echo "Directory:"

echo "$BASE_DIR"


echo

echo "Cloudflared:"

echo "$CF_BIN"


echo

echo "Log:"

echo "$LOG_FILE"


echo "=========="

}



#########################################
# 自动修复
#########################################

repair(){


echo "Checking..."


download_cf


create_cron_script


echo "Repair finished."


}

#########################################
# 增强菜单
#########################################

main_menu(){

clear

echo "=============================="
echo "      Argo Tunnel Panel"
echo "=============================="

load_config


echo
echo "Mode    : ${MODE}"
echo "Forward : ${FORWARD}"

if is_running
then

echo "Status  : Running"

else

echo "Status  : Stopped"

fi


echo

echo "1. Install cloudflared"

echo "2. Start Temporary Tunnel"

echo "3. Start Token Tunnel"

echo "4. Stop Tunnel"

echo "5. Restart Tunnel"

echo "6. Change Forward"

echo "7. Change Token"

echo "8. Change Mode"

echo "9. Install Cron Keepalive"

echo "10. Remove Cron"

echo "11. Status"

echo "12. Show Domain"

echo "13. Show Log"

echo "14. Show Config"

echo "15. Repair"

echo "16. Remove All"

echo "0. Exit"


echo

read -p "Select: " CMD


case "$CMD" in


1)

download_cf

;;


2)

MODE=temp

save_config

start_temp

;;


3)

MODE=token

save_config

start_token

;;


4)

stop_tunnel

;;


5)

restart_tunnel

;;


6)

change_port

;;


7)

change_token

;;


8)

set_mode

;;


9)

install_cron

;;


10)

remove_cron

;;


11)

status

;;


12)

show_domain

;;


13)

show_log

;;


14)

show_config

;;


15)

repair

;;


16)

remove_all

;;


0)

exit 0

;;


*)

echo "Invalid."

;;

esac


echo

read -p "Press Enter..."

}



#########################################
# 命令行模式
#########################################

cli_mode(){


case "$1" in


start)


load_config


case "$MODE" in

temp)

start_temp

;;

token)

start_token

;;

esac

;;


stop)


stop_tunnel

;;


restart)


restart_tunnel

;;


status)


status

;;


log)


show_log

;;


domain)


show_domain

;;


cron)


install_cron

;;


remove)


remove_all

;;


*)

echo

echo "Usage:"

echo

echo "$0 start"

echo "$0 stop"

echo "$0 restart"

echo "$0 status"

echo "$0 log"

echo "$0 domain"

echo "$0 cron"

echo "$0 remove"


;;


esac


exit 0

}



#########################################
# 初始化安装
#########################################

first_install(){


mkdir -p $BASE_DIR


init_config


detect_os


check_dependency


download_cf


echo

echo "Argo Panel initialized."

echo


}



#########################################
# Main Entry
#########################################


first_install


if [ $# -gt 0 ]

then

cli_mode "$@"

fi



while true

do

main_menu

done
