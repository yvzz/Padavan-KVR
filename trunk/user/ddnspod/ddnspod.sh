#!/bin/sh
#copyright by hiboy
# ArDNSPod (https://github.com/anrip/ArDNSPod) 接入脚本
# 基于 DNSPod 用户 API 的纯 Shell 动态域名客户端
export PATH='/etc/storage/bin:/tmp/script:/etc/storage/script:/opt/usr/sbin:/opt/usr/bin:/opt/sbin:/opt/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin'
export LD_LIBRARY_PATH=/lib:/opt/lib
ACTION=$1
scriptfilepath=$(cd "$(dirname "$0")"; pwd)/$(basename $0)
scriptpath=$(cd "$(dirname "$0")"; pwd)
scriptname=$(basename $0)

# 去掉 nvram 值里看不见的空白(网页里粘贴 token/域名/主机记录时很常见):
# 前后空格、\r、UTF-8 的 NBSP(\302\240)。这些字符会原样进 DNSPod 的 API 参数,
# 结果是 Record.List 的 sub_domain 过滤匹配不到已有记录(返回空 records),
# 而 Record.Create 按规范化后的名字判定"记录已存在" —— 正是
# "查不到 -> 创建报已存在" 死循环的成因之一, 所以在入口统一清掉。
ddnspod_clean () {
	echo "$1" | tr -d ' \t\r\n\302\240'
}

ddnspod_enable=`nvram get ddnspod_enable`
[ -z $ddnspod_enable ] && ddnspod_enable=0 && nvram set ddnspod_enable=0

if [ "$ddnspod_enable" != "0" ] ; then
ddnspod_interval=`nvram get ddnspod_interval`
ddnspod_token=$(ddnspod_clean "`nvram get ddnspod_token`")
ddnspod_domain=$(ddnspod_clean "`nvram get ddnspod_domain`")
ddnspod_name=$(ddnspod_clean "`nvram get ddnspod_name`")
ddnspod_domain2=$(ddnspod_clean "`nvram get ddnspod_domain2`")
ddnspod_name2=$(ddnspod_clean "`nvram get ddnspod_name2`")
ddnspod_domain6=$(ddnspod_clean "`nvram get ddnspod_domain6`")
ddnspod_name6=$(ddnspod_clean "`nvram get ddnspod_name6`")

if [ "$ddnspod_domain"x != "x" ] && [ "$ddnspod_name"x = "x" ] ; then
	ddnspod_name="www"
	nvram set ddnspod_name="www"
fi
if [ "$ddnspod_domain2"x != "x" ] && [ "$ddnspod_name2"x = "x" ] ; then
	ddnspod_name2="www"
	nvram set ddnspod_name2="www"
fi
if [ "$ddnspod_domain6"x != "x" ] && [ "$ddnspod_name6"x = "x" ] ; then
	ddnspod_name6="www"
	nvram set ddnspod_name6="www"
fi

[ -z $ddnspod_interval ] && ddnspod_interval=600 && nvram set ddnspod_interval=$ddnspod_interval
ddnspod_renum=`nvram get ddnspod_renum`

fi

if [ ! -z "$(echo $scriptfilepath | grep -v "/tmp/script/" | grep ddnspod)" ]  && [ ! -s /tmp/script/_ddnspod ]; then
	mkdir -p /tmp/script
	{ echo '#!/bin/sh' ; echo $scriptfilepath '"$@"' '&' ; } > /tmp/script/_ddnspod
	chmod 777 /tmp/script/_ddnspod
fi

ddnspod_restart () {

relock="/var/lock/ddnspod_restart.lock"
if [ "$1" = "o" ] ; then
	nvram set ddnspod_renum="0"
	[ -f $relock ] && rm -f $relock
	return 0
fi
if [ "$1" = "x" ] ; then
	if [ -f $relock ] ; then
		logger -t "【ddnspod】" "多次尝试启动失败，等待【"`cat $relock`"分钟】后自动尝试重新启动"
		exit 0
	fi
	ddnspod_renum=${ddnspod_renum:-"0"}
	ddnspod_renum=`expr $ddnspod_renum + 1`
	nvram set ddnspod_renum="$ddnspod_renum"
	if [ "$ddnspod_renum" -gt "2" ] ; then
		I=19
		echo $I > $relock
		logger -t "【ddnspod】" "多次尝试启动失败，等待【"`cat $relock`"分钟】后自动尝试重新启动"
		while [ $I -gt 0 ]; do
			I=$(($I - 1))
			echo $I > $relock
			sleep 60
			[ "$(nvram get ddnspod_renum)" = "0" ] && exit 0
			[ $I -lt 0 ] && break
		done
		nvram set ddnspod_renum="0"
	fi
	[ -f $relock ] && rm -f $relock
fi
nvram set ddnspod_status=0
eval "$scriptfilepath &"
exit 0
}

ddnspod_get_status () {

A_restart=`nvram get ddnspod_status`
B_restart="$ddnspod_enable$ddnspod_interval$ddnspod_token$ddnspod_domain$ddnspod_name$ddnspod_domain2$ddnspod_name2$ddnspod_domain6$ddnspod_name6"
B_restart=`echo -n "$B_restart" | md5sum | sed s/[[:space:]]//g | sed s/-//g`
if [ "$A_restart" != "$B_restart" ] ; then
	nvram set ddnspod_status=$B_restart
	needed_restart=1
else
	needed_restart=0
fi
}

ddnspod_check () {

ddnspod_get_status
if [ "$ddnspod_enable" != "1" ] && [ "$needed_restart" = "1" ] ; then
	[ ! -z "$(ps -w | grep "$scriptname keep" | grep -v grep )" ] && ddnspod_close
	{ kill_ps "$scriptname" exit0; exit 0; }
fi
if [ "$ddnspod_enable" = "1" ] ; then
	if [ "$needed_restart" = "1" ] ; then
		ddnspod_close
		eval "$scriptfilepath keep &"
		exit 0
	else
		[ -z "$(ps -w | grep "$scriptname keep" | grep -v grep )" ] || [ ! -s "`which curl`" ] && ddnspod_restart
	fi
fi
}

ddnspod_keep () {
ddnspod_start
logger -t "【DNSPod动态域名】" "守护进程启动"
while true; do
sleep $ddnspod_interval
[ ! -s "`which curl`" ] && ddnspod_restart
ddnspod_enable=`nvram get ddnspod_enable`
[ "$ddnspod_enable" = "0" ] && ddnspod_close && exit 0;
if [ "$ddnspod_enable" = "1" ] ; then
	ddnspod_start
fi
done
}

kill_ps () {

COMMAND="$1"
if [ ! -z "$COMMAND" ] ; then
	eval $(ps -w | grep "$COMMAND" | grep -v $$ | grep -v grep | awk '{print "kill "$1";";}')
	eval $(ps -w | grep "$COMMAND" | grep -v $$ | grep -v grep | awk '{print "kill -9 "$1";";}')
fi
if [ "$2" == "exit0" ] ; then
	exit 0
fi
}

ddnspod_close () {

kill_ps "/tmp/script/_ddnspod"
kill_ps "_ddnspod.sh"
kill_ps "$scriptname"

}

ddnspod_start () {
# 载入 ArDNSPod 函数库
if [ -s /usr/bin/ardnspod ] ; then
	. /usr/bin/ardnspod
fi
arToken="$ddnspod_token"
# ardnspod 默认 arIsCreateRecord=0(记录不存在时不创建), 与页面"记录不存在时自动创建(A 记录)"的说明不符
arIsCreateRecord=1
# 备用 IP 查询接口(国内可达)
arIp4QueryUrl="http://ipv4.ddnsip.cn"
arIp6QueryUrl="http://ipv6.ddnsip.cn"
if [ "$ddnspod_domain"x != "x" ] && [ "$ddnspod_name"x != "x" ] ; then
	sleep 1
	ddnspod_run "$ddnspod_domain" "$ddnspod_name"
fi
if [ "$ddnspod_domain2"x != "x" ] && [ "$ddnspod_name2"x != "x" ] ; then
	sleep 1
	ddnspod_run "$ddnspod_domain2" "$ddnspod_name2"
fi
if [ "$ddnspod_domain6"x != "x" ] && [ "$ddnspod_name6"x != "x" ] ; then
	sleep 1
	ddnspod_run "$ddnspod_domain6" "$ddnspod_name6" 6
fi

}

# 执行一次 arDdnsCheck, 输出进系统日志, 并把结果写进 nvram 供页面显示
ddnspod_run () {

if ! type arDdnsCheck >/dev/null 2>&1 ; then
	nvram set ddnspod_last_act="`date "+%Y-%m-%d %H:%M:%S"`   失败: 缺少 /usr/bin/ardnspod"
	logger -t "【DNSPod动态域名】" "缺少 /usr/bin/ardnspod, 无法更新"
	return 1
fi

if [ -z "$ddnspod_token" ] ; then
	nvram set ddnspod_last_act="`date "+%Y-%m-%d %H:%M:%S"`   失败: 未填写 API Token"
	logger -t "【DNSPod动态域名】" "未填写 API Token, 无法更新"
	return 1
fi

ddnspod_ret_out="$(arDdnsCheck "$1" "$2" "$3" 2>&1)"
echo "$ddnspod_ret_out" | logger -t "【DNSPod动态域名】"

case "$ddnspod_ret_out" in
	*updated:*)
		nvram set ddnspod_last_act="`date "+%Y-%m-%d %H:%M:%S"`   更新成功 -> $2.$1" ;;
	*unchanged:*)
		# IP 无变化即记录值与当前 IP 已一致, 结果等同于成功, 不算失败
		nvram set ddnspod_last_act="`date "+%Y-%m-%d %H:%M:%S"`   更新成功(IP 无变化, 无需更新) -> $2.$1" ;;
	*created:*)
		# 记录不存在时自动创建成功, 原先会漏判为失败
		nvram set ddnspod_last_act="`date "+%Y-%m-%d %H:%M:%S"`   创建记录成功 -> $2.$1" ;;
	*)
		# 失败时把 ardnspod 的具体报错直接写进状态, 免得只能去翻系统日志。
		# 注意顺序: 先取显式 "error: xxx"(例如真实原因"同名记录已存在(类型 CNAME), 与 A 冲突"),
		# 取不到才回退到"记录不存在"这类泛化文案, 否则真实原因会被泛化文案盖掉。
		ddnspod_err="$(echo "$ddnspod_ret_out" | grep -o 'error: [^"]*' | head -n 1 | sed 's/error: //')"
		if [ -z "$ddnspod_err" ] ; then
		case "$ddnspod_ret_out" in
			*"No records on the list"*|*"arDdnsLookup - Operation successful"*)
				# DNSPod api 调用成功(code=1)却查不到记录 id, 语义是"该主机记录不存在",
				# 不是出错也不是 IP 无变化
				ddnspod_err="解析记录不存在, 请检查域名与主机记录(自动创建未生效或创建失败)" ;;
			*)
				ddnspod_err="$(echo "$ddnspod_ret_out" | grep -o 'error: [^"]*' | head -n 1 | sed 's/error: //')"
				[ -z "$ddnspod_err" ] && ddnspod_err="$(echo "$ddnspod_ret_out" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p' | head -n 1)"
				[ -z "$ddnspod_err" ] && ddnspod_err="$(echo "$ddnspod_ret_out" | grep -v '^$' | tail -n 1)"
				[ -z "$ddnspod_err" ] && ddnspod_err="未知错误" ;;
		esac
		fi
		nvram set ddnspod_last_act="`date "+%Y-%m-%d %H:%M:%S"`   更新失败: $(echo "$ddnspod_err" | cut -c1-80)" ;;
esac
}

case $ACTION in
start)
	ddnspod_close
	ddnspod_check
	;;
check)
	ddnspod_check
	;;
stop)
	ddnspod_close
	;;
keep)
	ddnspod_keep
	;;
*)
	ddnspod_check
	;;
esac
