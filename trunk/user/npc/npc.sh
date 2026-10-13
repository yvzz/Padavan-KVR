#!/bin/sh
# npc (nps 客户端) 控制器
# 二进制不编译进固件: 启用时按需从 GitHub Releases 下载, 支持指定版本(留空=最新版)
#
# 两条重要约定:
# 1) 二进制默认放 /etc/storage/bin (flash), 而不是 /tmp
#    - /tmp 是 tmpfs, 放进去的每 1MB 都等于多吃 1MB 内存, npc 二进制约 9M
#    - 重启后 /tmp 清空, 每次开机都要重下, 容易和 5 分钟定时任务撞车形成下载风暴
#    空间不足时自动回退 /tmp/npc
# 2) 任何 start 都必须先干净地杀掉旧实例并等它真正退出
#    新旧实例并存会吃光内存和线程, tokio 起不来线程会直接 panic
#    (OS can't spawn worker thread: Resource temporarily unavailable, os error 11)

NPC_REPO="yisier/nps"
NPC_TARBALL="linux_mipsle_client.tar.gz"
NPC_FALLBACK_VER="v0.26.38"
# 页面「自定义仓库」可覆盖内置仓库。
# nps 原仓库(ehang-io/nps)早已停更(停在 v0.26.x), 社区二次维护版 djylb/nps 仍在活跃
# 更新(版本序列 v0.34.x), 且同样提供 linux_mipsle_client.tar.gz, 可直接填 djylb/nps。
# 换仓库后版本序列不同, 内置回退版本 v0.26.38 不再适用 —— 置空, 由用户指定版本或靠
# API 自动获取, 避免拼出 .../releases/download/v0.26.38/... 这种跨仓库的无效 URL。
# 页面上是二选一: yisier/nps(v0.26.x, 默认) / djylb/nps(v0.34.x, 社区维护版)。
# 空值(老配置)按默认处理, 其它文本按旧行为兼容(自定义仓库)。
_npc_repo_cfg=`nvram get npc_repo`
# NPC_CHANNEL: 自备仓库站(Padavan-depot)里对应的目录名, 只有内置的两个仓库有镜像
case "$_npc_repo_cfg" in
"yisier/nps"|"")
	NPC_REPO="yisier/nps"
	NPC_CHANNEL="yisier"
	;;
"djylb/nps")
	NPC_REPO="djylb/nps"
	NPC_CHANNEL="djylb"
	# 版本序列不同(v0.34.x), 内置回退版本 v0.26.38 不适用 —— 置空, 由 API 自动获取
	# 或页面「指定版本」填写, 避免拼出 .../releases/download/v0.26.38/... 这种跨仓库无效 URL
	NPC_FALLBACK_VER=""
	logger -t "【NPC】" "使用社区维护版仓库 djylb/nps(版本序列 v0.34.x)"
	;;
*)
	NPC_REPO="$_npc_repo_cfg"
	NPC_CHANNEL=""
	NPC_FALLBACK_VER=""
	logger -t "【NPC】" "使用自定义仓库 $NPC_REPO(自备仓库站无此渠道的镜像)"
	;;
esac
# 自备二进制仓库站(Padavan-depot)国内镜像基地址。
# 目录结构: $NPC_DEPOT/npc/<渠道>/linux_mipsle_client.tar.gz
# 留空时用内置默认(Gitee 镜像), 也可在页面/NVRAM 里改成 jsDelivr 或自建服务器。
NPC_DEPOT=`nvram get npc_depot`
[ -z "$NPC_DEPOT" ] && NPC_DEPOT="https://gitee.com/vvvv/Padavan-depot/raw/dist"
NPC_BIN_DIR=""		# 由 npc_pick_dir 决定
NPC_BIN=""		# 二进制完整路径
NPC_VER_FILE=""		# 版本标记文件
NPC_LOCK="/var/lock/npc.lock"
# 标记: 用于把老固件遗留的 /etc/storage/npc_script.sh 迁移成新版本(只迁移一次)
# 改动 npc_script.sh 逻辑时必须同步+1, 否则 /etc/storage 里的旧版不会被新版覆盖,
# 页面上的"服务器地址/端口"等设置改了也不生效(实际执行的始终是旧脚本)
NPC_SCRIPT_TAG="npc_script_v5"

npc_enable=`nvram get npc_enable`
http_username=`nvram get http_username`
[ -z "$http_username" ] && http_username=admin

# busybox wget 不一定支持 --no-check-certificate, 按需启用
WGET_SSL=""
if wget --help 2>&1 | grep -q "no-check-certificate" ; then
	WGET_SSL="--no-check-certificate"
fi

# 操作互斥锁: autostart / 页面应用 / 5 分钟定时任务可能同时触发 npc_start,
# 并发启动会拉起多个 npc 实例, 必须串行化
npc_lock_try()
{
	if mkdir "$NPC_LOCK" 2>/dev/null ; then
		date +%s > "$NPC_LOCK/ts"
		return 0
	fi
	# 僵死保护: 持锁进程异常退出留下空锁时, 超过 240 秒强制接管
	if [ -f "$NPC_LOCK/ts" ] ; then
		_now=`date +%s`
		_ts=`cat "$NPC_LOCK/ts" 2>/dev/null`
		[ -n "$_ts" ] || return 1
		[ "$_ts" -gt 0 ] 2>/dev/null || return 1
		[ $((_now - _ts)) -gt 240 ] || return 1
		rm -rf "$NPC_LOCK" 2>/dev/null
		mkdir "$NPC_LOCK" 2>/dev/null || return 1
		date +%s > "$NPC_LOCK/ts"
		return 0
	fi
	return 1
}

npc_lock_release()
{
	rm -rf "$NPC_LOCK" 2>/dev/null
}

# npc 是否还活着. 排除僵尸: 僵尸已不占资源, 但 pidof 仍能看到,
# 不排除会误判成"还在跑"而干等
npc_alive()
{
	for _p in `pidof npc 2>/dev/null` ; do
		[ "`awk '{print $3}' /proc/$_p/stat 2>/dev/null`" != "Z" ] && return 0
	done
	return 1
}

# 彻底停掉 npc 并等待真正退出(最多 15 秒)
npc_kill_wait()
{
	_i=0
	while [ $_i -lt 15 ] ; do
		npc_alive || return 0
		killall -9 npc 2>/dev/null
		killall -9 npc_script.sh 2>/dev/null
		sleep 1
		_i=$((_i+1))
	done
	npc_alive && return 1
	return 0
}

# 只保留一个实例(理论上不该出现多个, 出现就收敛, 避免内存/线程被吃光)
npc_single_check()
{
	_pids=`pidof npc 2>/dev/null`
	_cnt=0
	_first=""
	for _p in $_pids ; do
		_cnt=$((_cnt+1))
		[ $_cnt -eq 1 ] && _first=$_p
	done
	[ $_cnt -le 1 ] && return 0
	logger -t "【NPC】" "检测到 $_cnt 个 npc 实例, 只保留 PID $_first"
	for _p in $_pids ; do
		[ "$_p" = "$_first" ] || kill -9 "$_p" 2>/dev/null
	done
	return 0
}

# 选择二进制存放目录: 优先 /etc/storage/bin, 空间不足回退 /tmp/npc
npc_pick_dir()
{
	_avail=0
	NPC_BIN_DIR=""
	for _d in /etc/storage/bin /tmp/npc ; do
		mkdir -p "$_d" 2>/dev/null
		[ -d "$_d" ] || continue
		_avail=`df -k "$_d" 2>/dev/null | awk 'NR==2{print $4}'`
		[ -n "$_avail" ] || _avail=0
		# 约 16M: 二进制 ~9M + 压缩包 ~4M + 余量
		[ "$_avail" -ge 16384 ] 2>/dev/null || continue
		NPC_BIN_DIR="$_d"
		break
	done
	[ -z "$NPC_BIN_DIR" ] && NPC_BIN_DIR="/tmp/npc"
	NPC_BIN="$NPC_BIN_DIR/npc"
	NPC_VER_FILE="$NPC_BIN_DIR/npc.ver"
}

npc_set_dir()
{
	NPC_BIN_DIR="$1"
	NPC_BIN="$NPC_BIN_DIR/npc"
	NPC_VER_FILE="$NPC_BIN_DIR/npc.ver"
	mkdir -p "$NPC_BIN_DIR" 2>/dev/null
}

# 自愈/升级: /etc/storage/npc_script.sh 缺失, 或是老固件遗留下来的老版本(无标记)时从 /etc_ro 刷新
if [ ! -s "/etc/storage/npc_script.sh" ] || ! grep -q "$NPC_SCRIPT_TAG" /etc/storage/npc_script.sh 2>/dev/null ; then
	if [ -s "/etc_ro/npc_script.sh" ] ; then
		# 升级前备份旧脚本, 万一用户手改过内容不至于丢失
		[ -s "/etc/storage/npc_script.sh" ] && cp -f /etc/storage/npc_script.sh /etc/storage/npc_script.sh.bak
		cp -f /etc_ro/npc_script.sh /etc/storage/npc_script.sh
		chmod 755 /etc/storage/npc_script.sh
		logger -t "【NPC】" "npc_script.sh 已更新到 $NPC_SCRIPT_TAG (旧版备份为 npc_script.sh.bak)"
	fi
fi

check_net()
{
	/bin/ping -c 3 www.baidu.com -w 5 >/dev/null 2>&1
	if [ "$?" = "0" ]; then
		return 1
	else
		return 2
	fi
}

# 取 GitHub 上最新 release 的版本号
npc_latest_ver()
{
	_npc_tag=""
	if [ -x /usr/bin/curl ]; then
		_npc_tag=`curl -s -k --connect-timeout 5 --max-time 15 https://api.github.com/repos/$NPC_REPO/releases/latest 2>/dev/null | grep '"tag_name"' | head -n1 | cut -d'"' -f4`
	fi
	if [ -z "$_npc_tag" ]; then
		_npc_tag=`wget -q -T 5 -t 2 $WGET_SSL -O - https://api.github.com/repos/$NPC_REPO/releases/latest 2>/dev/null | grep '"tag_name"' | head -n1 | cut -d'"' -f4`
	fi
	echo "$_npc_tag"
}

# 取自备仓库站里当前镜像的版本号(version.txt), 拿不到返回空。
# 走国内镜像, 比 api.github.com 快且不会被墙; 失败不影响后面回退 GitHub。
npc_depot_ver()
{
	[ -z "$NPC_CHANNEL" ] && return 0
	_npc_dv=""
	# 必须 -L: Gitee 的 raw 会 302 跳到 raw.giteeusercontent.com, 不跟随会拿到跳转页面
	if [ -x /usr/bin/curl ]; then
		_npc_dv=`curl -s -L -k --connect-timeout 5 --max-time 10 "${NPC_DEPOT}/npc/${NPC_CHANNEL}/version.txt" 2>/dev/null | head -n1 | tr -d '\r'`
	fi
	if [ -z "$_npc_dv" ]; then
		_npc_dv=`wget -q -T 5 -t 1 $WGET_SSL -O - "${NPC_DEPOT}/npc/${NPC_CHANNEL}/version.txt" 2>/dev/null | head -n1 | tr -d '\r'`
	fi
	# 校验: 必须是 v 开头的版本号。拿到 302/404 的 HTML 页面时当作没取到, 交给后面的 GitHub 兜底
	case "$_npc_dv" in
	v[0-9]*) ;;
	*)
		[ -n "$_npc_dv" ] && logger -t "【NPC】" "镜像站 version.txt 返回异常, 忽略"
		_npc_dv=""
		;;
	esac
	echo "$_npc_dv"
}

# 下载文件: 优先 curl, 其次 wget; 成功返回 0
npc_dl()
{
	rm -f "$2"
	if [ -x /usr/bin/curl ]; then
		curl -L -k --connect-timeout 15 -o "$2" "$1" 2>/dev/null
	fi
	if [ ! -s "$2" ]; then
		wget -q -T 30 -t 2 $WGET_SSL -O "$2" "$1" 2>/dev/null
	fi
	[ -s "$2" ]
}

# 确保 $NPC_BIN 存在且版本匹配
npc_ensure_bin()
{
	npc_version=`nvram get npc_version`
	npc_url_cfg=`nvram get npc_url`
	npc_use_depot=0
	npc_dl_ver=""
	if [ -n "$npc_url_cfg" ]; then
		# 自定义直链: 完全绕开 GitHub(国内仓库 / 自建服务器 / 对象存储都可以)。
		# 版本标记直接用地址本身 —— 地址变了才会重新下载。
		npc_dl_ver="$npc_url_cfg"
		logger -t "【NPC】" "使用自定义下载地址 $npc_url_cfg"
	elif [ -n "$npc_version" ]; then
		# 指定了版本: 自备仓库站里只有最新版, 这种情况不走镜像
		npc_dl_ver="$npc_version"
	elif [ -n "$NPC_CHANNEL" ]; then
		# 先问自备仓库站(国内直连, 快), 拿不到再回退 GitHub API
		npc_dl_ver=`npc_depot_ver`
		if [ -n "$npc_dl_ver" ]; then
			npc_use_depot=1
			logger -t "【NPC】" "使用镜像站版本 $npc_dl_ver"
		fi
	fi
	if [ -z "$npc_dl_ver" ]; then
		if [ -n "$NPC_CHANNEL" ]; then
			logger -t "【NPC】" "镜像站未返回版本, 回退 GitHub API"
		fi
		npc_dl_ver=`npc_latest_ver`
		if [ -n "$npc_dl_ver" ]; then
			logger -t "【NPC】" "使用最新版本 $npc_dl_ver"
		elif [ -n "$NPC_FALLBACK_VER" ]; then
			npc_dl_ver="$NPC_FALLBACK_VER"
			logger -t "【NPC】" "获取最新版本失败, 使用 $npc_dl_ver"
		else
			# 自定义仓库: 版本序列与内置仓库不同, 没有可用的默认版本。
			# 这里必须 return, 否则会拼出 .../releases/download//xxx 这种空版本 URL。
			logger -t "【NPC】" "获取最新版本失败, 自定义仓库 $NPC_REPO 无默认版本, 请在页面「指定版本」填写(如 v0.34.7)"
			return 1
		fi
	fi

	mkdir -p "$NPC_BIN_DIR" 2>/dev/null

	# 已存在且版本一致, 无需重新下载
	if [ -s "$NPC_BIN" ] && [ "`cat $NPC_VER_FILE 2>/dev/null`" = "$npc_dl_ver" ]; then
		return 0
	fi

	logger -t "【NPC】" "开始下载 npc $npc_dl_ver 到 $NPC_BIN_DIR ..."
	rm -f $NPC_BIN $NPC_BIN_DIR/npc.tar.gz

	# 下载源顺序: 自定义直链 → 自备仓库站(国内镜像) → 页面填的加速源 → 直连 GitHub。
	# 与 easytier.sh 等其他插件保持同一套机制(此前 npc.sh 是硬编码 github.com,
	# 导致页面填的 github_proxy 对它完全无效)。
	if [ -n "$npc_url_cfg" ] ; then
		# 自定义直链本身就是完整 URL, 不再做前缀/路径拼接
		npc_proxys="$npc_url_cfg"
	else
		npc_proxys=""
		if [ "$npc_use_depot" = "1" ] ; then
			npc_proxys="DEPOT"
			logger -t "【NPC】" "镜像站: ${NPC_DEPOT}/npc/${NPC_CHANNEL}/${NPC_TARBALL}"
		fi
		npc_proxys="$npc_proxys `nvram get github_proxy` DIRECT"
		# 诊断用: 打印本次实际生效的源(值全部来自 nvram, 页面留空则只剩 DIRECT)。
		# 若这里出现未在页面填写过的源, 说明被「系统设置 -> 自定义脚本」里的 nvram set 写回了。
		logger -t "【NPC】" "下载源列表: $npc_proxys"
	fi

	for npc_proxy in $npc_proxys ; do
		# 自定义直链 = 完整 URL; DEPOT = 自备仓库站; 加速代理 = 前缀 + 完整 GitHub URL; DIRECT = 直连
		if [ -n "$npc_url_cfg" ] ; then
			npc_dl_url="$npc_url_cfg"
		elif [ "$npc_proxy" = "DEPOT" ] ; then
			npc_dl_url="${NPC_DEPOT}/npc/${NPC_CHANNEL}/${NPC_TARBALL}"
		elif [ "$npc_proxy" = "DIRECT" ] ; then
			npc_dl_url="https://github.com/${NPC_REPO}/releases/download/${npc_dl_ver}/${NPC_TARBALL}"
		else
			npc_dl_url="${npc_proxy}https://github.com/${NPC_REPO}/releases/download/${npc_dl_ver}/${NPC_TARBALL}"
		fi
		npc_dl "$npc_dl_url" "$NPC_BIN_DIR/npc.tar.gz"
		[ -s "$NPC_BIN_DIR/npc.tar.gz" ] && break
		logger -t "【NPC】" "源 ${npc_proxy} 下载失败, 换源重试"
	done

	if [ -s "$NPC_BIN_DIR/npc.tar.gz" ]; then
		tar -xz -C $NPC_BIN_DIR -f $NPC_BIN_DIR/npc.tar.gz 2>/dev/null
		rm -f $NPC_BIN_DIR/npc.tar.gz
		# 包内为 npc 与 conf/; 个别版本会多套一层 npc/ 目录
		[ -f $NPC_BIN_DIR/nps/npc ] && mv -f $NPC_BIN_DIR/nps/npc $NPC_BIN
		rm -rf $NPC_BIN_DIR/nps $NPC_BIN_DIR/conf
	fi

	if [ -s "$NPC_BIN" ]; then
		chmod 755 $NPC_BIN
		echo "$npc_dl_ver" > $NPC_VER_FILE
		nvram set npc_ver="$npc_dl_ver"
		logger -t "【NPC】" "npc $npc_dl_ver 下载完成"
		return 0
	fi

	nvram set npc_ver="下载失败"
	logger -t "【NPC】" "npc 下载失败(版本 $npc_dl_ver), 稍后自动重试"
	return 1
}

# 实际启动(调用前已持锁)
npc_start_locked()
{
	# 先停干净: 旧实例没退完就起新的, 两者并存最容易出现 tokio 起线程失败
	npc_kill_wait

	npc_pick_dir
	# 清掉另一处目录里的旧二进制, 免得 /tmp 里白留一份占内存
	[ "$NPC_BIN_DIR" = "/etc/storage/bin" ] && rm -f /tmp/npc/npc /tmp/npc/npc.ver /tmp/npc/npc.tar.gz 2>/dev/null
	rm -f "$NPC_BIN_DIR/npc.tar.gz" 2>/dev/null

	if ! npc_ensure_bin ; then
		# flash 上放不下就回退 /tmp 再试一次
		if [ "$NPC_BIN_DIR" != "/tmp/npc" ] ; then
			logger -t "【NPC】" "$NPC_BIN_DIR 空间不足, 回退 /tmp/npc"
			npc_set_dir "/tmp/npc"
			npc_ensure_bin || return 1
		else
			return 1
		fi
	fi

	if [ ! -s "/etc/storage/npc_script.sh" ]; then
		logger -t "【NPC】" "npc_script.sh 不存在, 无法启动"
		return 1
	fi
	/etc/storage/npc_script.sh
	sleep 2
	# 兜底: 万一还是起了多个, 只留一个
	npc_single_check

	sed -i '/npc/d' /etc/storage/cron/crontabs/$http_username 2>/dev/null
	cat >> /etc/storage/cron/crontabs/$http_username << EOF
*/5 * * * * /bin/sh /usr/bin/npc.sh C >/dev/null 2>&1
EOF
	if npc_alive ; then
		logger -t "【NPC】" "npc启动成功 (`pidof npc | wc -w` 个实例)"
		return 0
	fi
	logger -t "【NPC】" "npc启动失败, 请检查配置"
	return 1
}

npc_start()
{
	if ! npc_lock_try ; then
		logger -t "【NPC】" "已有 npc 操作在进行, 本次跳过(避免重复启动)"
		return 1
	fi
	npc_start_locked
	_rc=$?
	npc_lock_release
	return $_rc
}

npc_close()
{
	if ! npc_lock_try ; then
		logger -t "【NPC】" "已有 npc 操作在进行, 本次跳过"
		return 1
	fi
	npc_kill_wait
	sed -i '/npc/d' /etc/storage/cron/crontabs/$http_username 2>/dev/null
	logger -t "【NPC】" "已停止 npc"
	npc_lock_release
	return 0
}

check_npc()
{
	check_net
	result_net=$?
	if [ "$result_net" = "1" ] ;then
		if ! npc_alive && [ "$npc_enable" = "1" ];then
			npc_start
		fi
	else
		logger -t "【NPC】" "网络未就绪, 本次不重连"
	fi
}

case $1 in
start)
	npc_start
	;;
stop)
	npc_close
	;;
restart)
	npc_close
	npc_start
	;;
C)
	check_npc
	;;
esac
