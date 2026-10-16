#!/bin/sh

et_enable=$(nvram get easytier_enable)
config_server="$(nvram get easytier_config_server)"
et_core="$(nvram get easytier_bin)"
et_log="$(nvram get easytier_log)"
et_ports="$(nvram get easytier_ports)"
et_tunname="$(nvram get easytier_tunname)"
et_hostname="$(nvram get easytier_hostname)"
et_web_enable="$(nvram get easytier_web_enable)"
et_web_db="$(nvram get easytier_web_db)"
et_web_port="$(nvram get easytier_web_port)"
et_web_protocol="$(nvram get easytier_web_protocol)"
et_web_api="$(nvram get easytier_web_api)"
et_web_log="$(nvram get easytier_web_log)"
et_html_port="$(nvram get easytier_html_port)"
et_web_bin="$(nvram get easytier_web_bin)"
et_api_host="$(nvram get easytier_api_host)"
et_uuid="$(nvram get easytier_uuid)"
et_geoip="$(nvram get easytier_geoip)"
et_extra_args="$(nvram get easytier_extra_args)"
# 追加到 easytier-core 命令行末尾的自定义参数(页面"核心额外参数"), 留空表示不改
et_core_args="$(nvram get easytier_core_args)"
[ -z "$et_web_port" ] && et_web_port=22020
[ -z "$et_web_api" ] && et_web_port=11211
user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
# 国内镜像仓库(Gitee)按"基地址+GitHub路径"拼 URL。
# EasyTier 上游在国内 Gitee 同步了 release(easytier/EasyTier), 路径与 GitHub 完全一致,
# 且 Gitee 对 owner 大小写不敏感(实测 /EasyTier/EasyTier/... 同样返回 200),
# 因此把基地址换成 https://gitee.com/ 即可复用同一条路径, 无需任何目录改造。
# 实测 9.4MB 约 4.6 秒(2MB/s), 远快于 GitHub 直连。
# 顺序: 官方 Gitee 镜像 -> 直连, 404 由前置探测秒跳过。
gh_mirrors="https://gitee.com/"
# 不再内置/接受任何第三方加速代理(多数已失效 HTTP 000, 逐个探测纯属浪费时间);
# 末尾 DIRECT 为哨兵(循环中置空 = 直连), 保证镜像失效时仍能下载。
et_sources="$gh_mirrors DIRECT"
easytier_renum=`nvram get easytier_renum`

logg() {
  echo -e "\033[36;33m$(date +'%Y-%m-%d %H:%M:%S'):\033[0m\033[35;1m $1 \033[0m"
  echo "$(date +'%Y-%m-%d %H:%M:%S'): $1" >>/tmp/natpierce.log
  logger -t "【EasyTier】" "$1"
}

# 限制 tokio 工作线程数: 默认按 CPU 核数起线程, 小内存路由器上线程栈一多
# 就容易分配失败(EAGAIN), tokio 直接 panic:
#   OS can't spawn worker thread: Resource temporarily unavailable (os error 11)
[ -z "$TOKIO_WORKER_THREADS" ] && export TOKIO_WORKER_THREADS=2

# 进程是否活着(排除僵尸: 僵尸已不占资源, 但 pidof 仍能看到,
# 不排除会误判成"还在跑"而白等)
et_alive() {
	for _p in `pidof "$1" 2>/dev/null` ; do
		[ "`awk '{print $3}' /proc/$_p/stat 2>/dev/null`" != "Z" ] && return 0
	done
	return 1
}

# 杀干净并等它真正退出(最多 15 秒). 只发信号不等, 新旧实例并存就是
# 上面那个 tokio panic 的直接原因
et_kill_wait() {
	_i=0
	while [ $_i -lt 15 ] ; do
		et_alive "$1" || return 0
		killall -9 "$1" >/dev/null 2>&1
		sleep 1
		_i=$((_i+1))
	done
	et_alive "$1" && return 1
	return 0
}

# 只保留一个实例: 理论上不该出现多个, 出现就收敛, 免得内存/线程被吃光
et_single_check() {
	_pids=`pidof "$1" 2>/dev/null`
	_cnt=0
	_first=""
	for _p in $_pids ; do
		_cnt=$((_cnt+1))
		[ $_cnt -eq 1 ] && _first=$_p
	done
	[ $_cnt -le 1 ] && return 0
	logg "检测到 $_cnt 个 $1 实例, 只保留 PID $_first"
	for _p in $_pids ; do
		[ "$_p" = "$_first" ] || kill -9 "$_p" 2>/dev/null
	done
	return 0
}

# 取二进制落盘目录: 兼容用户自定义路径, 但绝不允许落到 /tmp 根目录。
# 背景(用户实测): /tmp 下除了 /tmp/easytier/easytier-core, 还莫名多出一个
# /tmp/easytier-core —— 原因是 nvram easytier_bin 可能是旧值或被手改成
# /tmp/easytier-core, 而下载函数统一用 `dirname "$et_core"` 取目录: dirname
# 得到 /tmp, 二进制就被直接铺在 /tmp 根, 与 /tmp/easytier/ 内的正式副本并存,
# 白白多占一份(约 9M, 小 tmpfs 上很致命)。
# 同理 easytier_bin 为空时 dirname 得到 ".", 会写进脚本当前工作目录。
et_dir_of() {
	_d="$(dirname "$1" 2>/dev/null)"
	case "$_d" in
	''|'.'|'/'|'/tmp')
		_d="$(et_pick_bin_dir)" ;;
	esac
	echo "$_d"
}

# 选二进制目录: 默认 /tmp/easytier/ (tmpfs, 重启即丢失但目录专属于本插件, 不会与其他插件
# 的 /tmp/var/ 冲突). 阈值 20M 保留为启动 sanity check (K2P /tmp 约 30M, core 约 7M, 留够
# 余量给 zip 解压时的临时文件).
et_pick_bin_dir() {
	for _cand in /tmp/easytier ; do
		mkdir -p "$_cand" 2>/dev/null
		[ -d "$_cand" ] || continue
		_avail=$(et_df_avail "$_cand")
		[ "$_avail" -ge 20480 ] 2>/dev/null || continue
		echo "$_cand"
		return 0
	done
	echo "/tmp/easytier"
}

# 启动/重启互斥锁: 页面应用、autostart、watchdog 守护、失败重试都可能同时触发 start,
# 并发启动正是多实例的来源. 240 秒或持锁进程已死时强制接管
et_lock="/var/lock/easytier_start.lock"
et_lock_try() {
	if mkdir "$et_lock" 2>/dev/null ; then
		date +%s > "$et_lock/ts"
		echo $$ > "$et_lock/pid"
		return 0
	fi
	_hold=$(cat "$et_lock/pid" 2>/dev/null)
	if [ -n "$_hold" ] && [ ! -d "/proc/$_hold" ] ; then
		rm -rf "$et_lock" 2>/dev/null
		mkdir "$et_lock" 2>/dev/null || return 1
		date +%s > "$et_lock/ts"
		echo $$ > "$et_lock/pid"
		return 0
	fi
	if [ -f "$et_lock/ts" ] ; then
		_ts=$(cat "$et_lock/ts" 2>/dev/null)
		_now=$(date +%s)
		[ -n "$_ts" ] || return 1
		[ "$_ts" -gt 0 ] 2>/dev/null || return 1
		[ $((_now - _ts)) -gt 240 ] || return 1
		rm -rf "$et_lock" 2>/dev/null
		mkdir "$et_lock" 2>/dev/null || return 1
		date +%s > "$et_lock/ts"
		echo $$ > "$et_lock/pid"
		return 0
	fi
	return 1
}
et_lock_release() {
	rm -rf "$et_lock" 2>/dev/null
}

# 下载互斥锁: 用 mkdir 原子性抢锁, 防止多个 start_core/start_web 并发下载互相踩踏、耗尽小 /tmp.
# 抢锁成功返回 0; 已有实例在下载则返回 1(调用方应直接退出, 等守护下次重试).
dl_lock="/var/lock/easytier_dl.lock"
# 启动/下载期标记: 记录最近一次 start_core / start_web 的发起时间戳。
# 背景: 守护进程(watchdog, 每 80 秒一轮)在"二进制还在下载、进程尚未起来"时会
# 误判"进程掉线"并再次 start —— 轻则刷一堆无用日志, 重则在"下载完成→进程启动"
# 这个窗口里把刚起来的进程又杀掉重来。有了标记, watchdog 在宽限期内直接跳过。
# 注意不能把 core_keep 挪到"运行成功之后"才注册: 那样下载失败就再也没人重试了。
et_start_mark="/tmp/easytier/.starting"
et_web_start_mark="/tmp/easytier/.starting_web"
# 宽限期(秒): 需覆盖"取版本 + 下载(zip 约 9.4M) + 解压 + 启动 + 自检"全程。
# 实测约 30~40 秒, 取 180 留足余量; 超过后 watchdog 恢复正常巡检。
et_start_grace=180
dl_lock_try() {
	if mkdir "$dl_lock" 2>/dev/null ; then
		return 0
	fi
	# 锁已存在, 判断是否超时残留(下载最长约 90+90 秒, 超过 240 秒视为僵死锁, 强制清除)
	if [ -f "$dl_lock/ts" ] ; then
		_ts=$(cat "$dl_lock/ts" 2>/dev/null)
		_now=$(date +%s)
		[ -n "$_ts" ] && [ $((_now - _ts)) -gt 240 ] && { rm -rf "$dl_lock"; mkdir "$dl_lock" 2>/dev/null && return 0; }
	fi
	return 1
}
dl_lock_release() {
	rm -rf "$dl_lock" 2>/dev/null
}
# 跨插件全局下载锁: 与 NPC 共用同一把锁(/var/lock/padavan_dl.lock)。
# 背景: 开机时 EasyTier 与 NPC 被 autostart 并行拉起, 各自都要往 /tmp 下载
# 十几兆的二进制, 而 /tmp 只有约 30M —— 同时下载必然有一方(或双方)写出截断的
# 二进制, 表现为"下载成功但运行失败/程序不完整"。这里让插件排队下载。
g_dl_lock="/var/lock/padavan_dl.lock"
g_dl_lock_wait() {
	_i=0
	while [ $_i -lt 150 ] ; do
		mkdir "$g_dl_lock" 2>/dev/null && { echo $$ > "$g_dl_lock/pid" 2>/dev/null; date +%s > "$g_dl_lock/ts" 2>/dev/null; return 0; }
		# 僵死锁保护: 持锁进程已不在(异常退出)或超过 300 秒未完成 -> 强制接管。
		# 存活判定优先用 kill -0: /proc 在部分环境不存在, 而 $$ 在子 shell/管道里
		# 又可能不是真正的持锁者, 只看 /proc 会把正常持锁误判成"已死"而抢锁。
		_hold=$(cat "$g_dl_lock/pid" 2>/dev/null)
		_dead=1
		if [ -n "$_hold" ] && kill -0 "$_hold" 2>/dev/null ; then
			_dead=0
		elif [ -d "/proc/$_hold" ] ; then
			_dead=0
		elif [ -n "$_hold" ] && [ ! -d "/proc/1" ] ; then
			# 没有 /proc 的环境无法确认, 保守按"还活着"处理(交给 300 秒超时兜底)
			_dead=0
		fi
		if [ "$_dead" = "1" ] ; then
			rm -rf "$g_dl_lock" 2>/dev/null
			continue
		fi
		_ts=$(cat "$g_dl_lock/ts" 2>/dev/null)
		if [ -n "$_ts" ] && [ $(( $(date +%s) - _ts )) -gt 300 ] ; then
			rm -rf "$g_dl_lock" 2>/dev/null
			continue
		fi
		sleep 2
		_i=$((_i+2))
	done
	return 1
}
g_dl_lock_release() {
	rm -rf "$g_dl_lock" 2>/dev/null
}

# 二进制完整性校验: 下载被中断/空间不足时 unzip 可能只解出半截文件,
# -s 判断不出来、-h 也可能照样输出几行帮助文本, 于是"看似下载成功"却一运行就崩。
# 用最小体积 + ELF 魔数双条件(与 npc.sh 的 npc_bin_ok 同一套思路)。
et_bin_size() {
	_sz=$(stat -c %s "$1" 2>/dev/null)
	case "$_sz" in
	''|*[!0-9]*) _sz=$(wc -c < "$1" 2>/dev/null | tr -d ' ') ;;
	esac
	case "$_sz" in
	''|*[!0-9]*) _sz=0 ;;
	esac
	echo "$_sz"
}
et_bin_why() {
	[ -s "$1" ] || { echo "文件不存在或为空"; return 1; }
	_sz=$(et_bin_size "$1")
	[ "$_sz" -lt 3145728 ] && { echo "体积异常: ${_sz} 字节(easytier-core 完整约 6.7M)"; return 1; }
	_magic=$(head -c 4 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
	case "$_magic" in
	7f454c46|'') return 0 ;;
	esac
	echo "不是 ELF 可执行文件(魔数 $_magic)"
	return 1
}
et_bin_ok() {
	et_bin_why "$1" >/dev/null 2>&1
}

# 取某目录可用空间(KB)。用 sed+cut 而不是 awk: 设备上的 awk 对某些写法直接
# 取不到值(曾让空间判断恒为 0/空, 导致误判"空间不足"去清理别的插件)。
et_df_avail() {
	_a=$(df -k "$1" 2>/dev/null | sed -n '2p' | tr -s ' ' ' ' | cut -d' ' -f4)
	case "$_a" in
	''|*[!0-9]*) _a=0 ;;
	esac
	echo "$_a"
}

# 读取持锁实例写入的下载进度(由 et_dl_timeout 每 5 秒更新到 $dl_lock/prog),
# 供并发实例在"已有实例正在下载, 本次跳过"时把进度显示出来,
# 否则日志是静默的, 分不清"正在正常下载"还是"已卡死".
et_dl_progress() {
	_prog="$(cat "$dl_lock/prog" 2>/dev/null)"
	[ -n "$_prog" ] || return 0
	_el=""
	if [ -f "$dl_lock/ts" ] ; then
		_ts=$(cat "$dl_lock/ts" 2>/dev/null)
		[ -n "$_ts" ] && _el="已耗时 $(( $(date +%s) - _ts ))s"
	fi
	echo " 进度[${_prog}]${_el:+ $_el}"
}

et_restart () {
relock="/var/lock/easytier_restart.lock"
if [ "$1" = "o" ] ; then
	nvram set easytier_renum="0"
	[ -f $relock ] && rm -f $relock
	return 0
fi
if [ "$1" = "x" ] ; then
	easytier_renum=${easytier_renum:-"0"}
	easytier_renum=`expr $easytier_renum + 1`
	nvram set easytier_renum="$easytier_renum"
	if [ "$easytier_renum" -gt "3" ] ; then
		I=19
		echo $I > $relock
		logg "多次尝试启动失败，等待【"`cat $relock`"分钟】后自动尝试重新启动"
		while [ $I -gt 0 ]; do
			I=$(($I - 1))
			echo $I > $relock
			sleep 60
			[ "$(nvram get easytier_renum)" = "0" ] && break
   			#[ "$(nvram get easytier_enable)" = "0" ] && exit 0
			[ $I -lt 0 ] && break
		done
		nvram set easytier_renum="1"
	fi
	[ -f $relock ] && rm -f $relock
fi
start_et
}

get_tag() {
	curltest=`which curl`
	logg "开始获取最新版本..."
    	if [ -z "$curltest" ] || [ ! -s "`which curl`" ] ; then
      		tag="$( wget --no-check-certificate -T 5 -t 3 --user-agent "$user_agent" --output-document=-  https://api.github.com/repos/EasyTier/EasyTier/releases/latest 2>&1 | grep 'tag_name' | cut -d\" -f4 )"
	 	[ -z "$tag" ] && tag="$( wget --no-check-certificate -T 5 -t 3 --user-agent "$user_agent" --quiet --output-document=-  https://api.github.com/repos/lmq8267/EasyTier/releases/latest  2>&1 | grep 'tag_name' | cut -d\" -f4 )"
    	else
      		tag="$( curl -k --connect-timeout 3 --max-time 8 --user-agent "$user_agent"  https://api.github.com/repos/EasyTier/EasyTier/releases/latest 2>&1 | grep 'tag_name' | cut -d\" -f4 )"
       	[ -z "$tag" ] && tag="$( curl -Lk --connect-timeout 3 --max-time 8 --user-agent "$user_agent" -s  https://api.github.com/repos/lmq8267/EasyTier/releases/latest  2>&1 | grep 'tag_name' | cut -d\" -f4 )"
        fi
	[ -z "$tag" ] && logg "无法获取最新版本"  
	nvram set easytier_ver_n=$tag
	if [ -f "$et_core" ] ; then
		chmod +x $et_core
		et_ver=$($et_core -V | awk '{print $2}' | tr -d ' ' | tr -d '\n')
		if [ -z "$et_ver" ] ; then
			nvram set easytier_ver=""
		else
			nvram set easytier_ver="v${et_ver}"
		fi
	fi
}

# 带外部硬超时的下载: 不依赖 curl/wget 自身的 --max-time(它们在 busybox/代理源上行为不可靠,
# 卡死时占死下载锁是"已有实例正在下载, 本次跳过"反复出现的直接原因). 后台跑下载 + 主进程计时,
# 超时强制 kill 掉下载进程, 保证任何情况下都能在 $3 秒内返回.
# 用法: et_dl_timeout <url> <out_file> <timeout秒>
et_dl_timeout() {
	_dl_url="$1"
	_dl_out="$2"
	_dl_timeout="${3:-60}"
	rm -f "$_dl_out"
	# 优先完整 curl(8.x 自带), 其次 busybox wget
	if [ -x /usr/bin/curl ] ; then
		curl -L -k --connect-timeout 15 -o "$_dl_out" "$_dl_url" 2>/dev/null &
	else
		wget --no-check-certificate -q -T 30 -O "$_dl_out" "$_dl_url" 2>/dev/null &
	fi
	_dl_pid=$!
	_dl_wait=0
	_dl_last=0
	_dl_stall=0
	while [ $_dl_wait -lt $_dl_timeout ] ; do
		# 下载进程已退出: 无论成功失败都立即返回
		kill -0 "$_dl_pid" 2>/dev/null || break
		# 每 5 秒报一次进度: 日志里能看到下载在推进还是卡死(大小长时间不变 = 卡死),
		# 并把进度写进锁目录, 供并发实例("已有实例正在下载, 本次跳过")读出来显示
		if [ $((_dl_wait % 5)) -eq 0 ] && [ $_dl_wait -gt 0 ] ; then
			_dl_now=$(stat -c %s "$_dl_out" 2>/dev/null)
			[ -n "$_dl_now" ] || _dl_now=0
			_dl_kb=$((_dl_now / 1024))
			_dl_sp=$(( (_dl_now - _dl_last) / 5 / 1024 ))
			[ "$_dl_now" -le "$_dl_last" ] && _dl_stall=$((_dl_stall + 5)) || _dl_stall=0
			# 阈值取 30 秒而非更短: 代理源(如 ghproxy)是"先去 GitHub 拉取再转发",
			# 准备期常常十几到二十几秒完全没有数据, 判太短会把正常等待误杀成卡死.
			# 总时长仍由 $_dl_timeout(60s)硬兜底, 这里只是提前止损省掉空等.
			if [ "$_dl_stall" -ge 30 ] ; then
				logg "下载卡死(${_dl_stall}秒无进展, 停在 ${_dl_kb} KB), 强制中止换源"
				kill -9 "$_dl_pid" 2>/dev/null
				wait "$_dl_pid" 2>/dev/null
				rm -f "$_dl_out"
				return 1
			fi
			logg "下载中 ${_dl_wait}s: 已下载 ${_dl_kb} KB (${_dl_sp} KB/s)"
			[ -d "$dl_lock" ] && echo "${_dl_kb}KB/${_dl_sp}KB per s/${_dl_wait}s" > "$dl_lock/prog" 2>/dev/null
			_dl_last=$_dl_now
		fi
		sleep 1
		_dl_wait=$((_dl_wait + 1))
	done
	# 超时仍未退出: 强制杀掉, 释放锁让后续源/watchdog 能继续
	if kill -0 "$_dl_pid" 2>/dev/null ; then
		kill -9 "$_dl_pid" 2>/dev/null
		wait "$_dl_pid" 2>/dev/null
		rm -f "$_dl_out"
		return 1
	fi
	wait "$_dl_pid" 2>/dev/null
	[ -s "$_dl_out" ]
}

# 官方源: EasyTier/EasyTier 的 easytier-linux-mipsel-<tag>.zip (内含 easytier-core / easytier-cli), 约 8.9M
dowload_et_official() {
	tag="$1"
	bin_path=$(et_dir_of "$et_core")
	[ ! -d "$bin_path" ] && mkdir -p "$bin_path"
	zip_name="easytier-linux-mipsel-${tag}.zip"
	for proxy in $et_sources ; do
	# 镜像=基地址+GitHub路径; DIRECT=直连
	if [ "$proxy" = "DIRECT" ] ; then
		gh_base="https://github.com/"
	else
		gh_base="$proxy"
	fi
	[ "$proxy" = "DIRECT" ] && proxy=""
	url="${gh_base}EasyTier/EasyTier/releases/download/${tag}/${zip_name}"
	# 前置探测: 失效的镜像站(连得上但转发不通)会卡满超时, 先 6 秒短探测, 非 200/302 直接跳过
	[ -n "$proxy" ] && {
		code=$(curl -sILk --connect-timeout 4 --max-time 6 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
		if [ "$code" != "200" ] && [ "$code" != "302" ]; then
			logg "源 ${proxy:-直连} 不可用(HTTP ${code:-超时}), 跳过"
			continue
		fi
	}
	logg "开始下载官方 $url"
	# 外部硬超时 60 秒(8.9M 包在几十 KB/s 的慢源上也够下完), 超时/失败即换源,
	# 兜底交给 watchdog 每 80 秒重试. 不再用 --speed-limit/--speed-time:
	# 代理源"先拉取 GitHub 文件再转发"的长时间无数据阶段会被它误判中断, 反复重连卡死
	et_dl_timeout "$url" "/tmp/${zip_name}" 60
	if [ ! -s /tmp/${zip_name} ] ; then
		# 下载失败: 清理残留, 换下一个源
		logg "源 ${proxy:-直连} 下载失败, 换源重试"
		rm -f /tmp/${zip_name}
		continue
	fi
	# 校验 zip 完整性: 空间不足或下载被中断时 zip 会被截断, 但文件仍"非空",
	# 只靠 -s 判断不出来。unzip -t 能提前发现, 避免解压出坏二进制后
	# 被误判成"版本不兼容"而锁死 30 分钟。
	if ! unzip -t /tmp/${zip_name} >/dev/null 2>&1 ; then
		logg "源 ${proxy:-直连} 下载的 zip 不完整(校验失败), 换源重试"
		rm -f /tmp/${zip_name}
		continue
	fi
	# 下载成功, 解压
	rm -rf /tmp/easytier_official
	mkdir -p /tmp/easytier_official
	# 只解出需要的两个成员(core 6.7M + cli 2.7M)。实测官方 zip 里就这两个文件,
	# 所以峰值不变; 但将来一旦混入 easytier-gui 之类大文件, 就不会被一股脑
	# 解出来白占 /tmp —— 小 tmpfs 上多解一个大文件就可能让下载半途失败。
	unzip -o /tmp/${zip_name} -d /tmp/easytier_official "*/easytier-core" "*/easytier-cli" 2>/dev/null
	if [ ! -f /tmp/easytier_official/easytier-linux-mipsel/easytier-core ] ; then
		# 成员列表写法在部分 busybox unzip 上不生效 -> 整体重解一次兜底
		unzip -o /tmp/${zip_name} -d /tmp/easytier_official 2>/dev/null
	fi
	if [ ! -f /tmp/easytier_official/easytier-linux-mipsel/easytier-core ] ; then
		# zip 内无此文件: 多半下到了错误页(HTML), 换源重试
		logg "下载内容异常(zip 内未找到二进制), 换源重试"
		rm -rf /tmp/${zip_name} /tmp/easytier_official
		continue
	fi
	# 解压成功, 二进制就位
	# 用 mv 而非 cp: 同分区内是 rename, 不额外占空间, 适配小容量 /tmp
	mv -f /tmp/easytier_official/easytier-linux-mipsel/easytier-core "$bin_path/easytier-core"
	chmod +x "$bin_path/easytier-core"
	if [ -f /tmp/easytier_official/easytier-linux-mipsel/easytier-cli ] ; then
		mv -f /tmp/easytier_official/easytier-linux-mipsel/easytier-cli "$bin_path/easytier-cli"
		chmod +x "$bin_path/easytier-cli"
	else
		# cli 只用于页面上的 peer/route/node 等状态查询, 缺了不影响 core 启动
		logg "未解出 easytier-cli(仅影响页面状态查询, 不影响启动)"
	fi
	# 二进制已就位: 立刻删掉 zip 与解压目录(合计约 19M), 给下面的 -h 运行测试腾空间。
	# 旧代码等到 -h 通过后才清理, 小 /tmp 上会因空间不足让 -h 失败,
	# 被误判成"版本不兼容"锁 30 分钟。
	rm -rf /tmp/${zip_name} /tmp/easytier_official
	# 测试能否运行: -h 输出 > 3 行才算正常
	if [[ "$($et_core -h 2>&1 | wc -l)" -gt 3 ]] ; then
		logg "$et_core 官方版本下载成功"
		et_ver=$($et_core -V | awk '{print $2}' | tr -d ' ' | tr -d '\n')
		if [ -z "$et_ver" ] ; then
			nvram set easytier_ver=""
		else
			nvram set easytier_ver="v${et_ver}"
		fi
		# 下载+运行测试通过, 清除"版本不可用"标记
		nvram set easytier_bin_bad=""
		rm -rf /tmp/${zip_name} /tmp/easytier_official
		return 0
	else
		# 走到这里说明: zip 完整性已校验通过、二进制也已解压出来, 但 -h 跑不起来。
		# 若是 /tmp 依然吃紧, 大概率是空间不足(而非版本不兼容) —— 绝不能锁死版本,
		# 否则要白白等 30 分钟才重试; 只有空间充裕仍失败, 才认定是版本真的不兼容
		# (换任何源下载的二进制都相同, 重下纯属浪费带宽并再次撑爆 /tmp)。
		_room=$(et_df_avail /tmp)
		if [ "$_room" -lt 5120 ] 2>/dev/null ; then
			logg "$et_core 启动测试失败, 但 /tmp 仅剩 ${_room}K(疑似空间不足), 不锁定版本, 稍后重试"
		else
			logg "官方版本 $tag 无法运行(-h 测试失败), 不再换源重试(换源下载的二进制相同)"
			nvram set easytier_bin_bad="$tag"
			nvram set easytier_bin_bad_ts="$(date +%s)"
		fi
		rm -f $et_core
		rm -rf /tmp/${zip_name} /tmp/easytier_official
		return 1
	fi
	done
	return 1
}

# 镜像兜底: lmq8267/EasyTier 的 easytier-mipsel-linux-muslsf.tar.gz (musl 软浮点), 约 15.5M
dowload_et_mirror() {
	tag="$1"
	bin_path=$(et_dir_of "$et_core")
	[ ! -d "$bin_path" ] && mkdir -p "$bin_path"
	logg "开始下载镜像 https://github.com/lmq8267/EasyTier/releases/download/${tag}/easytier-mipsel-linux-muslsf.tar.gz"
	for proxy in $et_sources ; do
	# 镜像=基地址+GitHub路径; DIRECT=直连
	if [ "$proxy" = "DIRECT" ] ; then
		gh_base="https://github.com/"
	else
		gh_base="$proxy"
	fi
	[ "$proxy" = "DIRECT" ] && proxy=""
	murl="${gh_base}lmq8267/EasyTier/releases/download/${tag}/easytier-mipsel-linux-muslsf.tar.gz"
	# 前置探测: 失效加速站快速跳过, 不进入长下载卡满超时
	[ -n "$proxy" ] && {
		code=$(curl -sILk --connect-timeout 4 --max-time 6 -o /dev/null -w "%{http_code}" "$murl" 2>/dev/null)
		if [ "$code" != "200" ] && [ "$code" != "302" ]; then
			logg "源 ${proxy:-直连} 不可用(HTTP ${code:-超时}), 跳过"
			continue
		fi
	}
 	length=$(wget --no-check-certificate -T 5 -t 3 "$murl" -O /dev/null --spider --server-response 2>&1 | grep "[Cc]ontent-[Ll]ength" | grep -Eo '[0-9]+' | tail -n 1)
 	length=`expr $length + 512000`
	length=`expr $length / 1048576`
 	et_size0="$(check_disk_size $bin_path)"
 	[ ! -z "$length" ] && logg "程序大小 ${length}M， 程序路径可用空间 ${et_size0}M "
	# 流式下载+解压, tar 包不落盘, 避免 16M tar + 20M 二进制双份占用撑爆小 /tmp
	# 先试 curl 管道解压, 失败再 wget 落盘后解压(部分老 busybox wget 不支持管道)
	curl -Lk --connect-timeout 5 --max-time 90 --retry 3 --retry-delay 2 --speed-limit 1024 --speed-time 15 "$murl" 2>/dev/null | tar -xzf - -O easytier-core > "$bin_path/easytier-core" 2>/dev/null
	curl -Lk --connect-timeout 5 --max-time 90 --retry 3 --retry-delay 2 --speed-limit 1024 --speed-time 15 "$murl" 2>/dev/null | tar -xzf - -O easytier-cli > "$bin_path/easytier-cli" 2>/dev/null
	if [ -s "$bin_path/easytier-core" ] && [ -s "$bin_path/easytier-cli" ] ; then
		chmod +x "$bin_path/easytier-core" "$bin_path/easytier-cli"
		chmod +x $et_core
		if [[ "$($et_core -h 2>&1 | wc -l)" -gt 3 ]] ; then
			logg "$et_core 下载成功"
			et_ver=$($et_core -V | awk '{print $2}' | tr -d ' ' | tr -d '\n')
			if [ -z "$et_ver" ] ; then
				nvram set easytier_ver=""
			else
				nvram set easytier_ver="v${et_ver}"
			fi
			break
		else
			logg "下载不完整，请手动下载 ${gh_base}lmq8267/EasyTier/releases/download/${tag}/easytier-mipsel-linux-muslsf.tar.gz 解压上传到  $et_core"
			rm -f "$bin_path/easytier-core" "$bin_path/easytier-cli"
		fi
	else
		# curl 管道解压失败, 回退 wget 落盘后解压
		rm -f "$bin_path/easytier-core" "$bin_path/easytier-cli"
		wget --no-check-certificate -T 30 -O /tmp/easytier-mipsel-linux-muslsf.tar.gz "${gh_base}lmq8267/EasyTier/releases/download/${tag}/easytier-mipsel-linux-muslsf.tar.gz" 2>/dev/null
		if [ -s /tmp/easytier-mipsel-linux-muslsf.tar.gz ] ; then
			tar -xzf /tmp/easytier-mipsel-linux-muslsf.tar.gz -O easytier-core > "$bin_path/easytier-core"
			tar -xzf /tmp/easytier-mipsel-linux-muslsf.tar.gz -O easytier-cli > "$bin_path/easytier-cli"
			chmod +x "$bin_path/easytier-core" "$bin_path/easytier-cli"
			rm -rf /tmp/easytier-mipsel-linux-muslsf.tar.gz
			if [ -s "$bin_path/easytier-core" ] && [[ "$($et_core -h 2>&1 | wc -l)" -gt 3 ]] ; then
				logg "$et_core 下载成功"
				et_ver=$($et_core -V | awk '{print $2}' | tr -d ' ' | tr -d '\n')
				[ -z "$et_ver" ] && nvram set easytier_ver="" || nvram set easytier_ver="v${et_ver}"
				break
			else
				logg "下载不完整，请手动下载 ${gh_base}lmq8267/EasyTier/releases/download/${tag}/easytier-mipsel-linux-muslsf.tar.gz 解压上传到  $et_core"
				rm -f "$bin_path/easytier-core" "$bin_path/easytier-cli"
			fi
		else
			logg "下载失败，请手动下载 ${gh_base}lmq8267/EasyTier/releases/download/${tag}/easytier-mipsel-linux-muslsf.tar.gz 上传到  $et_core"
			# 清理 wget 落盘残留的半截 tar 包, 避免小 /tmp 被占满
			rm -f /tmp/easytier-mipsel-linux-muslsf.tar.gz
		fi
	fi
	done
}

# 下载前检测 /tmp 空间; 不足时暂停 NPC 并清掉它在 /tmp 里的二进制腾空间,
# 记录到 /var/run/easytier_tmp_room 标记, 供 start_core 下载启动完成后恢复 NPC.
# 背景: K2P 的 /tmp 是 tmpfs 约 30M, EasyTier(约 9M) 与 NPC(约 9M) 的二进制都往
# /tmp 里放时会把空间挤爆, 导致双方下载/启动都失败.
et_make_tmp_room() {
	# 只清理 /tmp 下的 npc 二进制(/etc/storage/bin 里的不占 /tmp 空间)
	_avail=$(et_df_avail /tmp)
	# 阈值 18M(zip 约 9.4M + 解压后 core 6.7M + cli 2.7M ≈ 19M, 取略保守值):
	# 只有真放不下时才去停 NPC。旧阈值 32M 在 /tmp 只有 30M 的设备上恒为真,
	# 于是每次开机都先把正在下载的 NPC 杀掉 —— 这正是"NPC 下载失败/跳过"的来源;
	# 现在二进制下载已由全局锁串行化, NPC 不会再与 EasyTier 同时占空间。
	[ "$_avail" -ge 18432 ] 2>/dev/null && return 0

	rm -f /var/run/easytier_tmp_room 2>/dev/null
	# NPC 未启用, 或二进制不在 /tmp(在 flash), 无需也不应动
	[ "$(nvram get npc_enable)" = "1" ] || return 0
	# 不能因为 /tmp/npc/npc "还不存在或为空"就跳过:
	# 开机时 NPC 与 EasyTier 是并行拉起的, 此刻 NPC 往往刚开始下载、
	# 二进制尚未落地(-s 判定为假), 但紧接着就会占用约 9M。
	# 旧逻辑在这里提前 return, 于是 9M + 19M 一起把 tmpfs 撑爆。
	# 正确做法: 只要 NPC 开着就先停掉(阻止它继续下载), 再清 /tmp 里的残留。
	logg "/tmp 可用仅 ${_avail}K, 暂停 NPC 并清理其二进制腾空间"
	/usr/bin/npc.sh stop >/dev/null 2>&1
	rm -f /tmp/npc/npc /tmp/npc/npc.ver /tmp/npc/npc.tar.gz 2>/dev/null
	rm -rf /tmp/npc 2>/dev/null
	# 写标记: 本次腾过空间, 待 EasyTier 启动完成后恢复 NPC
	touch /var/run/easytier_tmp_room 2>/dev/null
}

# EasyTier 下载并启动完成后, 若之前为腾空间停过 NPC, 这里恢复它.
# 由 start_core 在下载/启动成功路径调用; 失败路径由守护下次重试时再恢复.
et_restore_npc() {
	[ -f /var/run/easytier_tmp_room ] || return 0
	rm -f /var/run/easytier_tmp_room 2>/dev/null
	# NPC 仍启用才恢复; 用户中途关掉就不拉起
	[ "$(nvram get npc_enable)" = "1" ] || return 0
	logg "EasyTier 已就绪, 恢复之前暂停的 NPC"
	/usr/bin/npc.sh start >/dev/null 2>&1 &
}

# 主入口: 先清旧残留腾空间, 只走官方源(8.9M 小包, 适配 K2P 30M 小 /tmp).
# 镜像源(16M tar + 20M 二进制)在小 /tmp 上根本放不下, 是"可用空间 0M"的元凶, 已移除.
dowload_et() {
	tag="$1"
	# 空间不足时先暂停 NPC 腾出 /tmp 空间, 避免与 NPC 二进制同时塞满 tmpfs
	et_make_tmp_room
	# 清理历史残留的下载包, 避免小容量 /tmp 被旧文件占满导致新下载放不下
	rm -f /tmp/easytier-linux-*.zip /tmp/easytier-mipsel-linux-*.tar.gz 2>/dev/null
	rm -rf /tmp/easytier_official 2>/dev/null
	# 官方源(8.9M zip)是唯一适配小 /tmp 的可靠来源; 失败则返回非 0, 由守护下次重试
	dowload_et_official "$tag"
}

dowload_web() {
	tag="$1"
	webbin_path=$(et_dir_of "$et_web_bin")
	[ ! -d "$webbin_path" ] && mkdir -p "$webbin_path"
	logg "开始下载 https://github.com/lmq8267/EasyTier/releases/download/${tag}/easytier-mipsel-linux-muslsf.tar.gz"
	for proxy in $et_sources ; do
	# 镜像=基地址+GitHub路径; DIRECT=直连
	if [ "$proxy" = "DIRECT" ] ; then
		gh_base="https://github.com/"
	else
		gh_base="$proxy"
	fi
	[ "$proxy" = "DIRECT" ] && proxy=""
 	length=$(wget --no-check-certificate -T 5 -t 3 "${gh_base}lmq8267/EasyTier/releases/download/${tag}/easytier-mipsel-linux-muslsf.tar.gz" -O /dev/null --spider --server-response 2>&1 | grep "[Cc]ontent-[Ll]ength" | grep -Eo '[0-9]+' | tail -n 1)
 	length=`expr $length + 512000`
	length=`expr $length / 1048576`
 	et_size0="$(check_disk_size $webbin_path)"
 	[ ! -z "$length" ] && logg "程序大小 ${length}M， 程序路径可用空间 ${et_size0}M "
        curl -Lko /tmp/easytier-mipsel-linux-muslsf.tar.gz --connect-timeout 5 --max-time 90 --retry 3 --retry-delay 2 --speed-limit 1024 --speed-time 15 "${gh_base}lmq8267/EasyTier/releases/download/${tag}/easytier-mipsel-linux-muslsf.tar.gz" || wget --no-check-certificate -T 30 -O /tmp/easytier-mipsel-linux-muslsf.tar.gz "${gh_base}lmq8267/EasyTier/releases/download/${tag}/easytier-mipsel-linux-muslsf.tar.gz"
	if [ "$?" = 0 ] ; then
		tar -xzf /tmp/easytier-mipsel-linux-muslsf.tar.gz -O easytier-web > "$webbin_path/easytier-web"
		chmod +x $et_web_bin
		if [[ "$($et_web_bin -h 2>&1 | wc -l)" -gt 3 ]] ; then
			logg "$et_web_bin 下载成功"
   			rm -rf /tmp/easytier-mipsel-linux-muslsf.tar.gz
			break
       		else
	   		logg "下载不完整，请手动下载 ${gh_base}lmq8267/EasyTier/releases/download/${tag}/easytier-mipsel-linux-muslsf.tar.gz 解压上传到  $et_web_bin"
	   		rm -f $et_web_bin
      			rm -rf /tmp/easytier-mipsel-linux-muslsf.tar.gz
	  	fi
	else
		logg "下载失败，请手动下载 ${gh_base}lmq8267/EasyTier/releases/download/${tag}/easytier-mipsel-linux-muslsf.tar.gz 上传到  $et_web_bin"
		# 清理下载失败残留的半截 tar 包
		rm -f /tmp/easytier-mipsel-linux-muslsf.tar.gz
   	fi
	done
}

update_et() {
	get_tag
	# 路径兜底: 页面"更新"按钮(web_ex.c: system("/usr/bin/easytier.sh update &"))
	# 直接走这里, 不经过 start_core 的路径纠正。若 easytier_bin 为空或指向
	# /tmp 根(如 /tmp/easytier-core), 先收敛到 /tmp/easytier/, 否则更新会把
	# 二进制重新铺到 /tmp 根, 形成与正式副本并存的重复文件。
	case "$et_core" in
	''|'/tmp/easytier-core'|'/tmp/easytier-cli')
		et_core="$(et_pick_bin_dir)/easytier-core"
		nvram set easytier_bin=$et_core ;;
	esac
	[ -z "$tag" ] && logg "无法获取最新版本" && exit 1
	tag=$(echo $tag | tr -d ' ' | tr -d '\n')
	# 注意: tag 必须保留前缀 v (下载地址里带 v), 比较版本时再各自剥掉 v
	tag_ver=$(echo $tag | tr -d 'v')
	et_ver=$(echo $et_ver | cut -d '-' -f1 | tr -d 'v' | tr -d ' ' | tr -d '\n')
	if [ ! -z "$tag" ] && [ ! -z "$et_ver" ] ; then
		if [ "$tag_ver"x != "$et_ver"x ] ; then
			logg "当前版本${et_ver} 最新版本${tag_ver}"
			dowload_et $tag
		else
			logg "当前已是最新版本 ${tag} 无需更新！"
		fi
	fi
	exit 0
}
scriptfilepath=$(cd "$(dirname "$0")"; pwd)/$(basename $0)
core_keep() {
	logg "Core守护进程启动"
	if [ -s /tmp/script/_opt_script_check ]; then
	sed -Ei '/【EasyTier_core】|^$/d' /tmp/script/_opt_script_check
	# 只保留"进程掉线→start"一条核心规则.
	# 防火墙/端口失效不再触发完整 start(那会并发重下载、互相踩踏耗尽小 /tmp),
	# 防火墙规则在 start_core 成功后的 et_rules 里会随进程一起重建.
	# 另外挂一条日志体积守护: /tmp/easytier.log 由 easytier-core 直接持有 fd 写入,
	# 这里截断只能释放实际占用的块, 进程的写偏移不会归零 —— 它下一次写会把文件撑回
	# 原来的"逻辑大小"(前面全是 '\0' 的稀疏文件, du 很小但 ls -l 看着很大)。
	# 所以阈值定小一点(1M), 并且页面侧只展示尾部(见 web_ex.c 的 easytier_tail.log)。
	cat >> "/tmp/script/_opt_script_check" <<-OSC
	_etmk=\`sed -n '1p' $et_start_mark 2>/dev/null | tr -d ' \r\n'\` ; case "$_etmk" in ''|*[!0-9]*) _etmk=0 ;; esac ; [ -z "\`pidof easytier-core\`" ] && [ $(( \`date +%s\` - _etmk )) -gt $et_start_grace ] && logger -t "进程守护" "EasyTier_core 进程掉线" && eval "$scriptfilepath start &" && sed -Ei '/【EasyTier_core】|^$/d' /tmp/script/_opt_script_check #【EasyTier_core】
	[ -z "\`pidof easytier-core\`" ] && [ $(( \`date +%s\` - _etmk )) -le $et_start_grace ] && logger -t "【EasyTier】" "启动/下载进行中, 守护本次跳过" #【EasyTier_core】
 	[ -s /tmp/easytier.log ] && [ "\$(stat -c %s /tmp/easytier.log)" -gt 1048576 ] && echo "" > /tmp/easytier.log & #【EasyTier_core】
	OSC
	fi

}

web_keep() {
	logg "Web守护进程启动"
	if [ -s /tmp/script/_opt_script_check ]; then
	sed -Ei '/【EasyTier_web】|^$/d' /tmp/script/_opt_script_check
	# 与 core_keep 同理, 只保留"进程掉线→start"一条核心规则.
	cat >> "/tmp/script/_opt_script_check" <<-OSC
	_etwmk=\`sed -n '1p' $et_web_start_mark 2>/dev/null | tr -d ' \r\n'\` ; case "$_etwmk" in ''|*[!0-9]*) _etwmk=0 ;; esac ; [ -z "\`pidof easytier-web\`" ] && [ $(( \`date +%s\` - _etwmk )) -gt $et_start_grace ] && logger -t "进程守护" "EasyTier_web 进程掉线" && eval "$scriptfilepath start &" && sed -Ei '/【EasyTier_web】|^$/d' /tmp/script/_opt_script_check #【EasyTier_web】
	[ -z "\`pidof easytier-web\`" ] && [ $(( \`date +%s\` - _etwmk )) -le $et_start_grace ] && logger -t "【EasyTier】" "Web 启动/下载进行中, 守护本次跳过" #【EasyTier_web】
 	[ -s /tmp/easytier_web.log ] && [ "\$(stat -c %s /tmp/easytier_web.log)" -gt 1048576 ] && echo "" > /tmp/easytier_web.log & #【EasyTier_web】
	OSC
	fi

}

et_rules() {
	if [ -z "$et_tunname" ] ; then
		tunname="tun0"
	else
		tunname="${et_tunname}"
	fi
	iptables -I INPUT -i ${tunname} -j ACCEPT
	iptables -I FORWARD -i ${tunname} -o ${tunname} -j ACCEPT
	iptables -I FORWARD -i ${tunname} -j ACCEPT
	iptables -t nat -I POSTROUTING -o ${tunname} -j MASQUERADE
	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
	if [ ! -z "$et_ports" ] ; then
		et_portss=$(echo $et_ports | tr -d '\r')
		for et_port in $et_portss ; do
			[ -z "$et_port" ] && continue
			iptables -I INPUT -p tcp --dport "$et_port" -j ACCEPT 
		 	ip6tables -I INPUT -p tcp --dport "$et_port" -j ACCEPT 
		 	iptables -I INPUT -p udp --dport "$et_port" -j ACCEPT
		 	ip6tables -I INPUT -p udp --dport "$et_port" -j ACCEPT 
		done	
	fi
	core_keep
}

start_core() {
	[ "$et_enable" = "0" ] && return 1
	mkdir -p /tmp/easytier 2>/dev/null
	date +%s > "$et_start_mark" 2>/dev/null
	logg "正在启动easytier-core"
  	if [ -z "$et_core" ] || [ "${et_core#/tmp/easytier/}" = "$et_core" ] ; then
		# 为空, 或仍是旧路径 (/tmp/var/... 或 /etc/storage/bin/...) -> 切到新默认 /tmp/easytier/
		_new_bin="$(et_pick_bin_dir)/easytier-core"
		# 旧路径有现成二进制则直接搬过来, 省一次下载
		if [ -n "$et_core" ] && [ -f "$et_core" ] && [ "$et_core" != "$_new_bin" ] ; then
			mkdir -p "$(dirname "$_new_bin")" 2>/dev/null
			mv -f "$et_core" "$_new_bin" 2>/dev/null && \
				logg "已将 $et_core 迁移到 $_new_bin"
		fi
		# 清理 /tmp/var/ 下的旧副本(可能 nvram 已空但磁盘还在)
		rm -f /tmp/var/easytier-core /tmp/var/easytier-cli 2>/dev/null
		et_core="$_new_bin"
  		nvram set easytier_bin=$et_core
    	fi
	# 清理 /tmp 根目录下的重复副本: 旧版本或手改路径曾把二进制直接落在 /tmp 下
	# (如 /tmp/easytier-core), 与 /tmp/easytier/ 内的正式副本并存。只有正式副本
	# 校验通过后才删, 避免把唯一一份可用的二进制删掉。
	case "$et_core" in
	/tmp/easytier/*)
		if et_bin_ok "$et_core" ; then
			rm -f /tmp/easytier-core /tmp/easytier-cli 2>/dev/null
		fi ;;
	esac
	# 兜底重试: 先把守护条目写入 _opt_script_check, 再走下载/启动.
	# 这样即使重启后下载失败、进程起不来, watchdog 也会每 80 秒重新 start 一次(含重下),
	# 摆脱 et_restart 的 19 分钟长退避死角, 保证"开启状态重启后能自动拉起".
	core_keep
	get_tag
 	if [ -f "$et_core" ] ; then
		[ ! -x "$et_core" ] && chmod +x $et_core
		# 完整性校验: -h 输出行数不可靠(截断的 ELF 仍能打印几行帮助后被判定"可用",
		# 于是接着运行 -> 秒退 -> 重启 19 分钟退避)。这里用 ELF 魔数 + 最小体积
		# 直接把残片拦掉并删除重下。
		if ! et_bin_ok "$et_core" ; then
			logg "程序${et_core}不完整：$(et_bin_why "$et_core")，删除后重新下载"
			rm -rf $et_core
		fi
  	fi
 	if [ ! -f "$et_core" ] ; then
		# 抢下载锁, 抢不到说明已有实例在下载, 直接退出等守护下次重试, 避免并发踩踏
		if ! dl_lock_try ; then
			logg "已有实例正在下载, 本次跳过$(et_dl_progress)"
			return 1
		fi
		date +%s > "$dl_lock/ts"
		# 跨插件排队: NPC 可能正在下载 16M 的二进制, 同时下必然写爆 /tmp
		if ! g_dl_lock_wait ; then
			logg "等待其他插件(NPC)下载超时, 本次跳过"
			dl_lock_release
			return 1
		fi
  		[ -z "$tag" ] && tag="v2.6.4"
		# 版本经测试无法运行时跳过下载(30 分钟内), 避免守护每 80 秒反复下载
		# 同一个跑不起来的版本形成死循环. 超过 30 分钟自动解除(也许版本更新了)
		_badtag="$(nvram get easytier_bin_bad)"
		if [ -n "$_badtag" ] && [ "$_badtag" = "$tag" ] ; then
			_badts="$(nvram get easytier_bin_bad_ts)"
			_now="$(date +%s)"
			if [ -n "$_badts" ] && [ $((_now - _badts)) -lt 1800 ] ; then
				logg "版本 $tag 近期测试无法运行, 跳过下载(30分钟内不重试, 请在页面指定其他版本)"
				dl_lock_release
				g_dl_lock_release
				return 1
			else
				nvram set easytier_bin_bad=""
				nvram set easytier_bin_bad_ts=""
			fi
		fi
		logg "主程序${et_core}不存在，开始在线下载..."
  		if ! dowload_et $tag ; then
  			dl_lock_release
  			g_dl_lock_release
  			logg "本次下载未成功, 不启动, 等待守护下次重试"
  			return 1
  		fi
		dl_lock_release
		g_dl_lock_release
  	fi
	sed -Ei '/【EasyTier_core】|^$/d' /tmp/script/_opt_script_check
	# 先杀干净再起: 旧实例没退完就起新的, 两者并存会吃光内存/线程,
	# tokio 建不出 worker 线程直接 panic (os error 11)
	et_kill_wait easytier-core
	bin_path=$(et_dir_of "$et_core")
	CMD=""
	if [ "$et_enable" = "1" ] ; then
		if [ -z "$config_server" ] ; then
			logg "Web服务器地址或用户名不能为空！程序退出！"
			exit 1
		fi
		[ -f /etc/storage/et_machine_id ] || touch /etc/storage/et_machine_id
		if [ ! -s /etc/storage/et_machine_id ]; then
			if [ -z "$et_uuid" ] ; then
				cat /proc/sys/kernel/random/uuid > /etc/storage/et_machine_id
				et_uuid="$(cat /etc/storage/et_machine_id | tr -d ' \n')"
				nvram set easytier_uuid="$et_uuid"
				nvram commit
				logg "/etc/storage/et_machine_id 为空，生成新的设备uuid $et_uuid"
			else
				echo "$et_uuid" > /etc/storage/et_machine_id
			fi
		fi
		core_uuid="$(cat /etc/storage/et_machine_id | tr -d ' \n')"
		#mkdir -p /var/lib/dbus
		#ln -sf /etc/storage/et_machine_id /var/lib/dbus/machine-id
		#[ -f "${bin_path}/et_machine_id" ] || ln -sf /etc/storage/et_machine_id ${bin_path}/et_machine_id
		[ "$et_log" = "1" ] && CMD="--console-log-level warn"
		[ "$et_log" = "2" ] && CMD="--console-log-level info"
		[ "$et_log" = "3" ] && CMD="--console-log-level debug"
		[ "$et_log" = "4" ] && CMD="--console-log-level trace"
		[ "$et_log" = "5" ] && CMD="--console-log-level error"
		[ -z "$core_uuid" ] || CMD=" --machine-id $core_uuid $CMD"
		[ ! -z "$et_hostname" ] && CMD="--hostname $et_hostname $CMD"
		CMD="-w $config_server $CMD"
	else
		[ "$et_log" = "1" ] && CMD="--console-log-level warn"
		[ "$et_log" = "2" ] && CMD="--console-log-level info"
		[ "$et_log" = "3" ] && CMD="--console-log-level debug"
		[ "$et_log" = "4" ] && CMD="--console-log-level trace"
		[ "$et_log" = "5" ] && CMD="--console-log-level error"
		CMD="-c /etc/storage/easytier.toml $CMD"
	fi
	# 用户自定义参数(easytier_core_args): 追加在命令行末尾 —— 后写的覆盖先写的,
	# 所以填 --lazy-p2p / --disable-p2p / -c /etc/storage/other.toml 都能生效。
	# 先过滤掉会破坏 shell 结构的字符, 防止页面输入被拆成多条命令执行。
	if [ -n "$et_core_args" ] ; then
		et_core_args="$(printf '%s' "$et_core_args" | tr '\n' ' ' | sed 's/[;&|<>`$]//g' | tr -s ' ')"
		if [ -n "$et_core_args" ] ; then
			CMD="$CMD $et_core_args"
			logg "已追加自定义参数: $et_core_args"
		fi
	fi
	# debug/trace 下 EasyTier 每秒能刷出上百行, /tmp/easytier.log 几十分钟就能到几 MB。
	# 守护每 80 秒截断一次(只释放实际占用), 但文件"逻辑大小"看起来仍很大, 属稀疏文件正常现象。
	case "$et_log" in
	3|4) logg "注意: 日志级别为调试/跟踪, /tmp/easytier.log 增长很快, 排障完建议改回警告/信息" ;;
	esac
	# 内联赋值 TOKIO_WORKER_THREADS: 不依赖 export 继承链(httpd system()/autostart & 的
	# 父环境里可能已存在同名变量导致第40行的 [ -z ] 不生效), 直接钉死在启动命令上,
	# 从根上避免 MT7621 按 CPU 核数起满线程 -> 栈分配失败 EAGAIN -> tokio panic (os error 11)
	[ -z "$ET_WORKER_THREADS" ] && ET_WORKER_THREADS=2
	etcmd="cd $bin_path ; TOKIO_WORKER_THREADS=$ET_WORKER_THREADS ./easytier-core ${CMD} >/tmp/easytier.log 2>&1"
	echo "$etcmd" >/tmp/easytier.CMD 
	logg "运行${etcmd}"
	eval "$etcmd" &
	sleep 4
	# 兜底: 万一还是起了多个(并发 start 等), 只留一个
	et_single_check easytier-core
	if [ ! -z "`pidof easytier-core`" ] ; then
 		mem=$(cat /proc/$(pidof easytier-core)/status | grep -w VmRSS | awk '{printf "%.1f MB", $2/1024}')
   		etcpu="$(top -b -n1 | grep -E "$(pidof easytier-core)" 2>/dev/null| grep -v grep | awk '{for (i=1;i<=NF;i++) {if ($i ~ /easytier-core/) break; else cpu=i}} END {print $cpu}')"
		logg "运行成功！"
  		logg "内存占用 ${mem} CPU占用 ${etcpu}%"
  		et_restart o
		echo `date +%s` > /tmp/easytier_time
		et_rules
		# 下载启动成功: 若之前为腾 /tmp 空间暂停过 NPC, 现在恢复它
		et_restore_npc
	else
		logg "运行失败, 注意检查${et_core}是否下载完整,10 秒后自动尝试重新启动"
  		sleep 10
  		et_restart x
	fi
	return 0
}

start_web() {
	[ "$et_web_enable" = "0" ] && return 1
	mkdir -p /tmp/easytier 2>/dev/null
	date +%s > "$et_web_start_mark" 2>/dev/null
	logg "正在启动easytier-web"
  	if [ -z "$et_web_bin" ] || [ "${et_web_bin#/tmp/easytier/}" = "$et_web_bin" ] ; then
		# 同上: 为空或仍是旧路径时切到新默认 /tmp/easytier/
		_new_bin="$(et_pick_bin_dir)/easytier-web"
		if [ -n "$et_web_bin" ] && [ -f "$et_web_bin" ] && [ "$et_web_bin" != "$_new_bin" ] ; then
			mkdir -p "$(dirname "$_new_bin")" 2>/dev/null
			mv -f "$et_web_bin" "$_new_bin" 2>/dev/null && \
				logg "已将 $et_web_bin 迁移到 $_new_bin"
		fi
		rm -f /tmp/var/easytier-web 2>/dev/null
		et_web_bin="$_new_bin"
  		nvram set easytier_web_bin=$et_web_bin
    	fi
	# 兜底重试: 与 start_core 同理, 先写守护条目, 下载失败也能被 watchdog 每 80 秒重试拉起
	web_keep
     	
    	if [ -f "$et_web_bin" ] ; then
		[ ! -x "$et_web_bin" ] && chmod +x $et_web_bin
  		[[ "$($et_web_bin -h 2>&1 | wc -l)" -lt 2 ]] && logg "程序${et_web_bin}不完整！" && rm -rf $et_web_bin
  	fi
 	if [ ! -f "$et_web_bin" ] ; then
		# 抢下载锁, 避免与 core 下载或其他实例并发踩踏
		if ! dl_lock_try ; then
			logg "已有实例正在下载, 本次跳过$(et_dl_progress)"
			return 1
		fi
		date +%s > "$dl_lock/ts"
  		get_tag
		logg "程序${et_web_bin}不存在，开始在线下载..."
  		[ -z "$tag" ] && tag="v2.6.4"
  		dowload_web $tag
		dl_lock_release
  	fi
	sed -Ei '/【EasyTier_web】|^$/d' /tmp/script/_opt_script_check
	# 原来这里根本没杀旧进程, 每次 start 都会多堆一个 web 实例(web 内存占用更大),
	# 是最容易把内存吃光的地方
	et_kill_wait easytier-web
	webCMD=""
	if [ ! -z "$et_web_db" ] ; then 
 		wdb_path=$(dirname "$et_web_db")
   		mkdir -p $wdb_path
 		webCMD="-d $et_web_db" 
   	fi
	[ -z "$et_web_port" ] || webCMD="${webCMD} -c $et_web_port" 
	[ -z "$et_web_protocol" ] || webCMD="${webCMD} -p $et_web_protocol" 
	[ -z "$et_web_api" ] || webCMD="${webCMD} -a $et_web_api" 
	if [ -z "$et_html_port" ] ; then
		webCMD="${webCMD} --no-web" 
	else
		webCMD="${webCMD} -l $et_html_port" 
	fi
	[ -z "$et_api_host" ] || webCMD="${webCMD} --api-host $et_api_host"
	[ -z "$et_geoip" ] || webCMD="${webCMD} --geoip-db $et_geoip"
	[ -z "$et_extra_args" ] || webCMD="${webCMD} $et_extra_args"
  	[ "$et_web_log" = "1" ] && webCMD="${webCMD} --console-log-level warn"
	[ "$et_web_log" = "2" ] && webCMD="${webCMD} --console-log-level info"
	[ "$et_web_log" = "3" ] && webCMD="${webCMD} --console-log-level debug"
	[ "$et_web_log" = "4" ] && webCMD="${webCMD} --console-log-level trace"
	[ "$et_web_log" = "5" ] && webCMD="${webCMD} --console-log-level error"
	wbin_path=$(et_dir_of "$et_web_bin")
	etwcmd="cd $wbin_path ; ./easytier-web ${webCMD} >/tmp/easytier_web.log 2>&1"
	logg "运行${etwcmd}"
	eval "$etwcmd" &
	sleep 4
	et_single_check easytier-web
	if [ ! -z "`pidof easytier-web`" ] ; then
 		wmem=$(cat /proc/$(pidof easytier-web)/status | grep -w VmRSS | awk '{printf "%.1f MB", $2/1024}')
   		etwcpu="$(top -b -n1 | grep -E "$(pidof easytier-web)" 2>/dev/null| grep -v grep | awk '{for (i=1;i<=NF;i++) {if ($i ~ /easytier-web/) break; else cpu=i}} END {print $cpu}')"
		logg "运行成功！"
  		logg "内存占用 ${wmem} CPU占用 ${etwcpu}%"
  		et_restart o
  		web_keep
    		iptables -I INPUT -p tcp --dport "$et_web_port" -j ACCEPT 
		ip6tables -I INPUT -p tcp --dport "$et_web_port" -j ACCEPT
		iptables -I INPUT -p udp --dport "$et_web_port" -j ACCEPT 
		ip6tables -I INPUT -p udp --dport "$et_web_port" -j ACCEPT
  		iptables -I INPUT -p tcp --dport "$et_web_api" -j ACCEPT
		ip6tables -I INPUT -p tcp --dport "$et_web_api" -j ACCEPT
		iptables -I INPUT -p udp --dport "$et_web_api" -j ACCEPT
		ip6tables -I INPUT -p udp --dport "$et_web_api" -j ACCEPT
		if [ ! -z "$et_html_port" ] ; then
			iptables -I INPUT -p tcp --dport "$et_html_port" -j ACCEPT 
			ip6tables -I INPUT -p tcp --dport "$et_html_port" -j ACCEPT
		fi
	else
		logg "运行失败, 注意检查${et_web_bin}是否下载完整,10 秒后自动尝试重新启动"
  		sleep 10
  		et_restart x
	fi
	return 0
	
}

start_et() {
	# 页面应用 / autostart / watchdog 守护 / 失败重试都可能同时触发 start,
	# 并发启动会拉起多个实例 -> 内存和线程被吃光 -> tokio panic, 必须串行化.
	# 用重入计数: et_restart 的重试是在本 shell 内递归调 start_et, 不能把自己挡在门外
	ET_LOCK_DEPTH=$((ET_LOCK_DEPTH + 1))
	if [ "$ET_LOCK_DEPTH" -eq 1 ] && ! et_lock_try ; then
		logg "已有启动操作在进行, 本次跳过(避免多实例并存)"
		ET_LOCK_DEPTH=$((ET_LOCK_DEPTH - 1))
		return 1
	fi
	start_core
	start_web
	ET_LOCK_DEPTH=$((ET_LOCK_DEPTH - 1))
	[ "$ET_LOCK_DEPTH" -le 0 ] && { ET_LOCK_DEPTH=0; et_lock_release; }
	return 0
}

stop_et() {
	logg  "正在关闭..."
	sed -Ei '/【EasyTier_core】|^$/d' /tmp/script/_opt_script_check
	sed -Ei '/【EasyTier_web】|^$/d' /tmp/script/_opt_script_check
	scriptname=$(basename $0)
	if [ -z "$et_tunname" ] ; then
		tunname="tun0"
	else
		tunname="${et_tunname}"
	fi
	killall easytier-core >/dev/null 2>&1
	killall easytier-web >/dev/null 2>&1
	# 一并终止卡死的下载进程(失效源上 curl 会卡满 --max-time 反复重试, 占死下载锁),
	# 并释放下载锁: 否则"停止"后紧接着的 start 会一直报"已有实例正在下载, 本次跳过".
	# 只杀命令行里带 EasyTier 的 curl/wget, 避免误伤 NPC/DDNS 等其他插件的下载
	eval $(ps -w | grep -E "[c]url|[w]get" | grep -i "EasyTier" | awk '{print "kill "$1";"}')
	dl_lock_release
	# 等真正退出: 否则紧接着的 start 会和还没死的旧进程并存
	et_kill_wait easytier-core
	et_kill_wait easytier-web
	if [ ! -z "$et_ports" ] ; then
		et_portss=$(echo $et_ports | tr -d '\r')
		for et_port in $et_portss ; do
			[ -z "$et_port" ] && continue
			iptables -D INPUT -p tcp --dport "$et_port" -j ACCEPT >/dev/null 2>&1
		 	ip6tables -D INPUT -p tcp --dport "$et_port" -j ACCEPT >/dev/null 2>&1
		 	iptables -D INPUT -p udp --dport "$et_port" -j ACCEPT >/dev/null 2>&1
		 	ip6tables -D INPUT -p udp --dport "$et_port" -j ACCEPT >/dev/null 2>&1
		done	
	fi
	iptables -D INPUT -i ${tunname} -j ACCEPT 2>/dev/null
	iptables -D FORWARD -i ${tunname} -o ${tunname} -j ACCEPT 2>/dev/null
	iptables -D FORWARD -i ${tunname} -j ACCEPT 2>/dev/null
	iptables -t nat -D POSTROUTING -o ${tunname} -j MASQUERADE 2>/dev/null
 	iptables -D INPUT -p tcp --dport "$et_web_port" -j ACCEPT >/dev/null 2>&1
	ip6tables -D INPUT -p tcp --dport "$et_web_port" -j ACCEPT >/dev/null 2>&1
	iptables -D INPUT -p udp --dport "$et_web_port" -j ACCEPT >/dev/null 2>&1
	ip6tables -D INPUT -p udp --dport "$et_web_port" -j ACCEPT >/dev/null 2>&1
  	iptables -D INPUT -p tcp --dport "$et_web_api" -j ACCEPT >/dev/null 2>&1
	ip6tables -D INPUT -p tcp --dport "$et_web_api" -j ACCEPT >/dev/null 2>&1
	iptables -D INPUT -p udp --dport "$et_web_api" -j ACCEPT >/dev/null 2>&1
	ip6tables -D INPUT -p udp --dport "$et_web_api" -j ACCEPT >/dev/null 2>&1
	if [ ! -z "$et_html_port" ] ; then
		iptables -D INPUT -p tcp --dport "$et_html_port" -j ACCEPT >/dev/null 2>&1
		ip6tables -D INPUT -p tcp --dport "$et_html_port" -j ACCEPT >/dev/null 2>&1
	fi
	[ -z "`pidof easytier-core`" ] && [ -z "`pidof easytier-web`" ] && logg "进程已关闭!"
	if [ ! -z "$scriptname" ] ; then
		eval $(ps -w | grep "$scriptname" | grep -v $$ | grep -v grep | awk '{print "kill "$1";";}')
		eval $(ps -w | grep "$scriptname" | grep -v $$ | grep -v grep | awk '{print "kill -9 "$1";";}')
	fi
}

et_error="错误：${et_core} 未运行，请运行成功后执行此操作！"
et_process=$(pidof easytier-core)
etpath=$(dirname "$et_core")
cmdfile="/tmp/easytier_cmd.log"

peer() {
	if [ ! -z "$et_process" ] ; then
		cd $etpath
  		[ ! -x "${etpath}/easytier-cli" ] && chmod +x ${etpath}/easytier-cli
		./easytier-cli peer >$cmdfile 2>&1
	else
		echo "$et_error" >$cmdfile 2>&1
	fi
	exit 1
}

connector() {
	if [ ! -z "$et_process" ] ; then
		cd $etpath
  		[ ! -x "${etpath}/easytier-cli" ] && chmod +x ${etpath}/easytier-cli
		./easytier-cli connector >$cmdfile 2>&1
	else
		echo "$et_error" >$cmdfile 2>&1
	fi
	exit 1
}

stun() {
	if [ ! -z "$et_process" ] ; then
		cd $etpath
  		[ ! -x "${etpath}/easytier-cli" ] && chmod +x ${etpath}/easytier-cli
		./easytier-cli stun >$cmdfile 2>&1
	else
		echo "$et_error" >$cmdfile 2>&1
	fi
	exit 1
}

route() {
	if [ ! -z "$et_process" ] ; then
		cd $etpath
  		[ ! -x "${etpath}/easytier-cli" ] && chmod +x ${etpath}/easytier-cli
		./easytier-cli route >$cmdfile 2>&1
	else
		echo "$et_error" >$cmdfile 2>&1
	fi
	exit 1
}

peer_center() {
	if [ ! -z "$et_process" ] ; then
		cd $etpath
  		[ ! -x "${etpath}/easytier-cli" ] && chmod +x ${etpath}/easytier-cli
		./easytier-cli peer-center >$cmdfile 2>&1
	else
		echo "$et_error" >$cmdfile 2>&1
	fi
	exit 1
}

vpn_portal() {
	if [ ! -z "$et_process" ] ; then
		cd $etpath
  		[ ! -x "${etpath}/easytier-cli" ] && chmod +x ${etpath}/easytier-cli
		./easytier-cli vpn-portal >$cmdfile 2>&1
	else
		echo "$et_error" >$cmdfile 2>&1
	fi
	exit 1
}

node() {
	if [ ! -z "$et_process" ] ; then
		cd $etpath
  		[ ! -x "${etpath}/easytier-cli" ] && chmod +x ${etpath}/easytier-cli
		./easytier-cli node >$cmdfile 2>&1
	else
		echo "$et_error" >$cmdfile 2>&1
	fi
	exit 1
}

proxy() {
	if [ ! -z "$et_process" ] ; then
		cd $etpath
  		[ ! -x "${etpath}/easytier-cli" ] && chmod +x ${etpath}/easytier-cli
		./easytier-cli proxy >$cmdfile 2>&1
	else
		echo "$et_error" >$cmdfile 2>&1
	fi
	exit 1
}

status() {
	if [ ! -z "$et_process" ] ; then
		etcpu="$(top -b -n1 | grep -E "$(pidof easytier-core)" 2>/dev/null| grep -v grep | awk '{for (i=1;i<=NF;i++) {if ($i ~ /easytier-core/) break; else cpu=i}} END {print $cpu}')"
		echo -e "\t\t easytier-core 运行状态\n" >$cmdfile
		[ ! -z "$etcpu" ] && echo "CPU占用 ${etcpu}% " >>$cmdfile 2>&1
		etram="$(cat /proc/$(pidof easytier-core | awk '{print $NF}')/status|grep -w VmRSS|awk '{printf "%.2fMB\n", $2/1024}')"
		[ ! -z "$etram" ] && echo "内存占用 ${etram}" >>$cmdfile 2>&1
		ettime=$(cat /tmp/easytier_time) 
		if [ -n "$ettime" ] ; then
			time=$(( `date +%s`-ettime))
			day=$((time/86400))
			[ "$day" = "0" ] && day=''|| day=" $day天"
			time=`date -u -d @${time} +%H小时%M分%S秒`
		fi
		[ ! -z "$time" ] && echo "已运行 $time" >>$cmdfile 2>&1
		cmdtart=$(cat /tmp/easytier.CMD)
		[ ! -z "$cmdtart" ] && echo "启动参数  $cmdtart" >>$cmdfile 2>&1
		
	else
		echo "$et_error" >$cmdfile
	fi
	exit 1
}

case $1 in
start)
	start_et &
	;;
stop)
	stop_et
	;;
restart)
	stop_et
	# 用户手动重启: 清除"版本不可用"标记, 允许重新下载测试
	nvram set easytier_bin_bad=""
	nvram set easytier_bin_bad_ts=""
	start_et &
	;;
update)
	update_et &
	;;
peer)
	peer
	;;
connector)
	connector
	;;
stun)
	stun
	;;
route)
	route
	;;
peer-center)
	peer_center
	;;
vpn-portal)
	vpn_portal
	;;
node)
	node
	;;
proxy)
	proxy
	;;
status)
	status
	;;
*)
	echo "check"
	#exit 0
	;;
esac
