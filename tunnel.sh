#!/bin/bash

#############################################
# Argo Tunnel Panel
# Version 1.0
#############################################

BASE_DIR="/etc/argo-panel"

CONFIG="$BASE_DIR/config.conf"
LOG="$BASE_DIR/argo.log"
PID="$BASE_DIR/argo.pid"
CF="$BASE_DIR/cloudflared"
DOMAIN="$BASE_DIR/domain"

mkdir -p "$BASE_DIR"


#############################################
# 初始化配置
#############################################

init_config(){

if [ ! -f "$CONFIG" ];then

cat > "$CONFIG" <<EOF
MODE=temp
FORWARD=127.0.0.1:8080
TOKEN=
DOMAIN=
EOF

fi

}



#############################################
# 读取配置
#############################################

load_config(){

source "$CONFIG"

}



#############################################
# 保存配置
#############################################

save_config(){

cat > "$CONFIG" <<EOF
MODE=$MODE
FORWARD=$FORWARD
TOKEN=$TOKEN
DOMAIN=$DOMAIN
EOF

}



#############################################
# 架构检测
#############################################

get_arch(){

case "$(uname -m)" in

x86_64)

ARCH="amd64"

;;

aarch64)

ARCH="arm64"

;;

armv7l)

ARCH="arm"

;;

i386|i686)

ARCH="386"

;;

*)

echo "Unsupported architecture"

exit 1

;;

esac

}



#############################################
# 安装cloudflared
#############################################

install_cloudflared(){


if [ -f "$CF" ];then

return

fi


get_arch


echo "Downloading cloudflared..."



if command -v curl >/dev/null

then


curl -L \
"https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH" \
-o "$CF"


elif command -v wget >/dev/null

then


wget \
"https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH" \
-O "$CF"


else


echo "Need curl or wget"

exit 1


fi



chmod +x "$CF"


echo "cloudflared installed."

}



#############################################
# 判断运行状态
#############################################

is_running(){

if [ ! -f "$PID" ];then

return 1

fi


kill -0 "$(cat "$PID")" 2>/dev/null

}



#############################################
# 停止Tunnel
#############################################

stop_tunnel(){

if is_running

then

kill "$(cat "$PID")"

rm -f "$PID"

echo "Stopped"

else

echo "Not running"

fi

}


#############################################
# 获取临时Tunnel域名
#############################################

get_domain(){

sleep 5


DOMAIN_URL=$(grep -oE \
"https://[-a-zA-Z0-9.]+trycloudflare.com" \
"$LOG" | head -1)


if [ -n "$DOMAIN_URL" ];then


DOMAIN=$(echo "$DOMAIN_URL" | sed 's#https://##')


load_config

save_config


echo "$DOMAIN" > "$DOMAIN"


fi

}



#############################################
# 启动临时Tunnel
#############################################

start_temp(){

load_config

install_cloudflared


if is_running

then

echo "Tunnel already running"

return

fi


echo "Starting temporary tunnel..."



rm -f "$LOG"



nohup "$CF" tunnel \
--no-autoupdate \
--url "http://$FORWARD" \
>>"$LOG" 2>&1 &



echo $! > "$PID"



get_domain



echo

echo "Tunnel started"

echo


if [ -f "$DOMAIN" ];then

echo "Domain:"

cat "$DOMAIN"

fi


}



#############################################
# 启动Token Tunnel
#############################################

start_token(){

load_config

install_cloudflared



if [ -z "$TOKEN" ];then


echo

read -p "Input Tunnel Token: " TOKEN


save_config


fi



if [ -z "$TOKEN" ];then

echo "Token empty"

return

fi



if is_running

then

echo "Tunnel already running"

return

fi



echo "Starting token tunnel..."



rm -f "$LOG"



nohup "$CF" tunnel run \
--no-autoupdate \
--token "$TOKEN" \
>>"$LOG" 2>&1 &



echo $! > "$PID"



echo "Token tunnel started"



}



#############################################
# 重启Tunnel
#############################################

restart_tunnel(){

stop_tunnel


sleep 2


load_config


if [ "$MODE" = "token" ];then


start_token


else


start_temp


fi


}



#############################################
# 修改转发地址
#############################################

change_forward(){


load_config


echo

echo "Current:"

echo "$FORWARD"


echo


read -p "New forward: " NEW_FORWARD



if [ -z "$NEW_FORWARD" ];then

return

fi



FORWARD="$NEW_FORWARD"


save_config



echo "Saved"

echo "Restart required"



}



#############################################
# 修改模式
#############################################

change_mode(){


echo

echo "1.Temp Tunnel"

echo "2.Token Tunnel"


read -p "Select: " MODE_CHOOSE



case "$MODE_CHOOSE" in


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


echo "Mode changed"

}



#############################################
# 查看日志
#############################################

show_log(){

if [ -f "$LOG" ];then

tail -50 "$LOG"

else

echo "No log"

fi

}



#############################################
# 查看状态
#############################################

show_status(){

load_config


echo

echo "================"

echo "Mode    : $MODE"

echo "Forward : $FORWARD"

echo "Domain  : $DOMAIN"


if is_running

then

echo "Status  : Running"

echo "PID     : $(cat $PID)"

else

echo "Status  : Stopped"

fi


echo "================"

}

#############################################
# 创建crond保活脚本
#############################################

create_keepalive(){


KEEP="$BASE_DIR/keepalive.sh"



cat > "$KEEP" <<EOF
#!/bin/sh


BASE_DIR="$BASE_DIR"

PID="\$BASE_DIR/argo.pid"

CFG="\$BASE_DIR/config.conf"

CF="\$BASE_DIR/cloudflared"

LOG="\$BASE_DIR/argo.log"


[ -f "\$CFG" ] || exit 0


. "\$CFG"



running(){

[ -f "\$PID" ] || return 1

kill -0 \$(cat "\$PID") 2>/dev/null

}



if running

then

exit 0

fi



case "\$MODE" in


temp)


nohup "\$CF" tunnel \
--no-autoupdate \
--url "http://\$FORWARD" \
>>"\$LOG" 2>&1 &


echo \$! > "\$PID"


;;



token)


nohup "\$CF" tunnel run \
--no-autoupdate \
--token "\$TOKEN" \
>>"\$LOG" 2>&1 &


echo \$! > "\$PID"


;;


esac

EOF


chmod +x "$KEEP"


}



#############################################
# 安装crond
#############################################

install_cron(){


create_keepalive


if ! command -v crontab >/dev/null

then

echo "crontab not found"

echo "Please install cron first"

return

fi



(crontab -l 2>/dev/null | grep -v keepalive.sh

echo "* * * * * $BASE_DIR/keepalive.sh") | crontab -



echo

echo "Cron installed"

}



#############################################
# 删除安装
#############################################

uninstall(){


stop_tunnel


crontab -l 2>/dev/null \
| grep -v keepalive.sh \
| crontab -


rm -rf "$BASE_DIR"


echo "Removed"

exit 0

}



#############################################
# 显示域名
#############################################

show_domain(){


if [ -f "$DOMAIN" ];then

echo

echo "Tunnel Domain:"

cat "$DOMAIN"


else

echo "No domain"

fi

}



#############################################
# 主菜单
#############################################

menu(){


while true

do


echo

echo "=========================="

echo "    Argo Tunnel Panel"

echo "=========================="


load_config



echo "Mode: $MODE"

echo "Forward: $FORWARD"



if is_running

then

echo "Status: Running"

else

echo "Status: Stop"

fi



echo

echo "1.Start Temp Tunnel"

echo "2.Start Token Tunnel"

echo "3.Stop Tunnel"

echo "4.Restart Tunnel"

echo "5.Change Forward"

echo "6.Change Mode"

echo "7.Status"

echo "8.Log"

echo "9.Domain"

echo "10.Install Cron"

echo "11.Remove"

echo "0.Exit"



echo


read -p "Select: " NUM



case "$NUM" in


1)

MODE=temp

save_config

start_temp

;;


2)

MODE=token

save_config

start_token

;;


3)

stop_tunnel

;;


4)

restart_tunnel

;;


5)

change_forward

;;


6)

change_mode

;;


7)

show_status

;;


8)

show_log

;;


9)

show_domain

;;


10)

install_cron

;;


11)

uninstall

;;


0)

exit 0

;;


*)

echo "Invalid"

;;

esac


done

}



#############################################
# 命令模式
#############################################

command_mode(){


case "$1" in


start)

load_config


if [ "$MODE" = "token" ]

then

start_token

else

start_temp

fi

;;


stop)

stop_tunnel

;;


restart)

restart_tunnel

;;


status)

show_status

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

uninstall

;;


*)

echo

echo "Usage:"

echo "$0 start"

echo "$0 stop"

echo "$0 restart"

echo "$0 status"

echo "$0 log"

echo "$0 cron"

echo "$0 remove"

;;

esac


exit 0

}



#############################################
# 程序入口
#############################################

init_config


if [ $# -gt 0 ]

then

command_mode "$1"

fi



menu
