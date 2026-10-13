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

# 只保留 yisier/nps(v0.26.x) 一个渠道:
# nps 原仓库(ehang-io/nps)早已停更(停在 v0.26.x); 社区二次维护版 djylb/nps(v0.34.x)
# 实测连不上 0.26.x 的服务端(进程起来立刻退出), 已整条移除 —— 客户端必须与服务端版本匹配。
NPC_REPO="yisier/nps"
# NPC_CHANNEL: 自备仓库站(Padavan-depot)里对应的目录名
NPC_CHANNEL="yisier"
NPC_TARBALL="linux_mipsle_client.tar.gz"
# 镜像站/GitHub API 都拿不到版本时的兜底版本(属于同一 v0.26.x 序列)
NPC_FALLBACK_VER="v0.26.38"
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
		# 用 cut 而不是 awk: 设备上的 awk 对部分写法直接匹配不到(取到空值),
		# 空值会让空间判断失效。tr -s 压缩空格后取第 4 列(可用 KB)。
		_avail=`df -k "$_d" 2>/dev/null | sed -n '2p' | tr -s ' ' ' ' | cut -d' ' -f4`
		case "$_avail" in
		''|*[!0-9]*) _avail=0 ;;
		esac
		# 流式解包峰值约 17M(本体 16187607 字节), 留余量取 20M。
		# 老阈值 16M 是按"本体 9M"估的, 明显不够; 但也不能定太高(如 32M),
		# 否则 /tmp 只有 30M 时会全部跳过、退化成"永远用 /tmp"。
		[ "$_avail" -ge 20480 ] || continue
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

# 二进制是否可用。
# 下载被中断(断电/断网/双实例并发)时 tar 可能只解出半个文件, -s 判断为"存在",
# 但跑起来立刻崩溃退出 —— 表现为"npc 已启动"然后 2 秒后"启动失败", 且因为
# 版本标记已写入, 后续每次重启都认为"已下载过"而一直复用这个坏文件。
# 这里用 ELF 魔数 + 最小体积两个条件把它拦出来。
npc_bin_ok()
{
	[ -s "$NPC_BIN" ] || { echo "文件不存在或为空"; return 1; }
	# 体积: 优先 stat, 取不到就退到 wc -c(不同 busybox 编译项不一样)
	_npc_sz=`stat -c %s "$NPC_BIN" 2>/dev/null`
	case "$_npc_sz" in
	''|*[!0-9]*) _npc_sz=`wc -c < "$NPC_BIN" 2>/dev/null | tr -d ' '` ;;
	esac
	case "$_npc_sz" in
	''|*[!0-9]*) _npc_sz=0 ;;
	esac
	# 完整本体 16187607 字节; 解包时空间不足只会写出残片, 远小于 8M
	[ "$_npc_sz" -lt 8388608 ] && { echo "体积异常: ${_npc_sz} 字节(完整约 16.2M)"; return 1; }
	# ELF 魔数 7f 45 4c 46(不是 ELF 说明拿到的是 HTML 错误页之类)。
	# od 不可用时取不到魔数, 这种情况不能判失败, 交给体积判断兜底。
	_npc_magic=`head -c 4 "$NPC_BIN" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n'`
	case "$_npc_magic" in
	7f454c46|'') return 0 ;;
	esac
	echo "不是 ELF 可执行文件(魔数 $_npc_magic)"
	return 1
}

# 下载并解包一次(只负责把包拿下来解开, 结果由调用方判断)。
# 参数: $1=版本 $2=是否走镜像站 $3=自定义直链(可空)
# 下载源顺序: 自定义直链 → 自备仓库站(国内镜像) → 直连 GitHub。
# 不再读取 github_proxy(加速源功能已从固件移除)。
npc_dl_once()
{
	_dl_ver="$1"
	_use_depot="$2"
	_url_cfg="$3"

	if [ -n "$_url_cfg" ] ; then
		# 自定义直链本身就是完整 URL, 不再做前缀/路径拼接
		npc_proxys="$_url_cfg"
	else
		npc_proxys=""
		if [ "$_use_depot" = "1" ] ; then
			npc_proxys="DEPOT"
			logger -t "【NPC】" "镜像站: ${NPC_DEPOT}/npc/${NPC_CHANNEL}/${NPC_TARBALL}"
		fi
		npc_proxys="$npc_proxys DIRECT"
		logger -t "【NPC】" "下载源列表: $npc_proxys"
	fi

	for npc_proxy in $npc_proxys ; do
		# 自定义直链 = 完整 URL; DEPOT = 自备仓库站; DIRECT = 直连
		if [ -n "$_url_cfg" ] ; then
			npc_dl_url="$_url_cfg"
		elif [ "$npc_proxy" = "DEPOT" ] ; then
			npc_dl_url="${NPC_DEPOT}/npc/${NPC_CHANNEL}/${NPC_TARBALL}"
		else
			npc_dl_url="https://github.com/${NPC_REPO}/releases/download/${_dl_ver}/${NPC_TARBALL}"
		fi

		# 主路径: 边下边解(不落压缩包)。
		# 先落盘再解需要同时容纳压缩包 5.4M + 本体 16.2M ≈ 22M, 而 /tmp 总共只有 30M
		# 且 EasyTier 常驻占约 9M —— 实测可用空间常年在 20M 上下, 正好卡在临界值,
		# 于是时好时坏(同一份好包, 有时成功有时写出残片)。流式解包峰值只要 16.2M。
		# curl 的退出码用标记文件带出来(管道里 $? 只能拿到 tar 的)。
		if [ -x /usr/bin/curl ] ; then
			rm -f $NPC_BIN "$NPC_BIN_DIR/.dl_ok"
			{ curl -L -k --connect-timeout 15 --max-time 300 "$npc_dl_url" 2>/dev/null && touch "$NPC_BIN_DIR/.dl_ok" ; } | tar -xz -C $NPC_BIN_DIR -f - 2>/dev/null
			_npc_tar_rc=$?
			_npc_curl_ok=0
			[ -f "$NPC_BIN_DIR/.dl_ok" ] && _npc_curl_ok=1
			rm -f "$NPC_BIN_DIR/.dl_ok"
			[ -f $NPC_BIN_DIR/nps/npc ] && mv -f $NPC_BIN_DIR/nps/npc $NPC_BIN
			rm -rf $NPC_BIN_DIR/nps $NPC_BIN_DIR/conf
			chmod 755 $NPC_BIN 2>/dev/null
			# tar 遇到截断的 gzip 会退出非 0 —— 这是识别残包的关键,
			# 光看体积不行(残包可能被补齐成同样大小)
			if [ "$_npc_curl_ok" = "1" ] && [ "$_npc_tar_rc" = "0" ] && npc_bin_ok ; then
				logger -t "【NPC】" "流式下载并解包成功(源 ${npc_proxy})"
				return 0
			fi
			logger -t "【NPC】" "流式解包未成功(源 ${npc_proxy}: curl=$_npc_curl_ok tar=$_npc_tar_rc), 改用落盘方式"
			rm -f $NPC_BIN
		fi

		# 兜底: 落盘 + gzip -t 校验后再解
		npc_dl "$npc_dl_url" "$NPC_BIN_DIR/npc.tar.gz"
		if [ ! -s "$NPC_BIN_DIR/npc.tar.gz" ]; then
			logger -t "【NPC】" "源 ${npc_proxy} 下载失败, 换源重试"
			continue
		fi
		# 下载被中断时包是截断的, -s 判断不出来, gzip -t 能验出来
		gzip -t "$NPC_BIN_DIR/npc.tar.gz" >/dev/null 2>&1
		_npc_gz=$?
		# 127 = 环境里没有 gzip, 这种情况下无法校验, 不能因此判失败
		if [ "$_npc_gz" != "0" ] && [ "$_npc_gz" != "127" ] ; then
			logger -t "【NPC】" "源 ${npc_proxy} 下载不完整(gzip 校验失败), 换源重试"
			rm -f "$NPC_BIN_DIR/npc.tar.gz"
			continue
		fi
		tar -xz -C $NPC_BIN_DIR -f $NPC_BIN_DIR/npc.tar.gz 2>/dev/null
		rm -f $NPC_BIN_DIR/npc.tar.gz
		# 包内为 npc 与 conf/; 个别版本会多套一层 npc/ 目录
		[ -f $NPC_BIN_DIR/nps/npc ] && mv -f $NPC_BIN_DIR/nps/npc $NPC_BIN
		rm -rf $NPC_BIN_DIR/nps $NPC_BIN_DIR/conf
		chmod 755 $NPC_BIN 2>/dev/null
		npc_bin_ok && return 0
		logger -t "【NPC】" "源 ${npc_proxy} 解包结果不可用($(_npc_why=`npc_bin_ok`; echo "$_npc_why")), 换源重试"
		rm -f $NPC_BIN
	done
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
	else
		# 先问自备仓库站(国内直连, 快), 拿不到再回退 GitHub API
		npc_dl_ver=`npc_depot_ver`
		if [ -n "$npc_dl_ver" ]; then
			npc_use_depot=1
			logger -t "【NPC】" "使用镜像站版本 $npc_dl_ver"
		fi
	fi
	if [ -z "$npc_dl_ver" ]; then
		logger -t "【NPC】" "镜像站未返回版本, 回退 GitHub API"
		npc_dl_ver=`npc_latest_ver`
		if [ -n "$npc_dl_ver" ]; then
			logger -t "【NPC】" "使用最新版本 $npc_dl_ver"
		elif [ -n "$NPC_FALLBACK_VER" ]; then
			npc_dl_ver="$NPC_FALLBACK_VER"
			logger -t "【NPC】" "获取最新版本失败, 使用 $npc_dl_ver"
		else
			# 这里必须 return, 否则会拼出 .../releases/download//xxx 这种空版本 URL。
			logger -t "【NPC】" "获取最新版本失败, 请在页面「指定版本」填写(如 v0.26.38)"
			return 1
		fi
	fi

	mkdir -p "$NPC_BIN_DIR" 2>/dev/null

	# 已存在、版本一致、且二进制本身完整, 才跳过下载。
	# 只比对版本是不够的: 截断的残片也会带着正确的版本标记, 于是永远不会被重下。
	if [ -s "$NPC_BIN" ] && [ "`cat $NPC_VER_FILE 2>/dev/null`" = "$npc_dl_ver" ] && npc_bin_ok ; then
		return 0
	fi
	# 走到这里说明不存在/版本变了/文件坏了 —— 明确提示一下, 排障时一眼能看出
	[ -s "$NPC_BIN" ] && logger -t "【NPC】" "已存在的 npc 二进制不完整或版本不匹配, 重新下载"

	logger -t "【NPC】" "开始下载 npc $npc_dl_ver 到 $NPC_BIN_DIR ..."
	# 空间诊断: 流式解包峰值约 17M(本体 16.2M), 落盘兜底路径约 22M。
	# 空间不够时 tar 会写出残片, 表现为"下载完成但启动即退出", 所以每次都打出来。
	logger -t "【NPC】" "可用空间: /etc/storage/bin `df -k /etc/storage/bin 2>/dev/null | sed -n '2p' | tr -s ' ' ' ' | cut -d' ' -f4` KB, /tmp `df -k /tmp 2>/dev/null | sed -n '2p' | tr -s ' ' ' ' | cut -d' ' -f4` KB"
	rm -f $NPC_BIN $NPC_BIN_DIR/npc.tar.gz
	# npc_dl_once 内部已遍历所有源、并会在流式失败时改走落盘+gzip校验, 这里不再重复重试
	npc_dl_once "$npc_dl_ver" "$npc_use_depot" "$npc_url_cfg"
	chmod 755 $NPC_BIN 2>/dev/null

	if npc_bin_ok ; then
		echo "$npc_dl_ver" > $NPC_VER_FILE
		nvram set npc_ver="$npc_dl_ver"
		logger -t "【NPC】" "npc $npc_dl_ver 下载完成"
		return 0
	fi
	logger -t "【NPC】" "npc 二进制校验失败($(_npc_why=`npc_bin_ok`; echo "$_npc_why")), 已删除, 稍后重试"
	rm -f $NPC_BIN $NPC_VER_FILE 2>/dev/null

	logger -t "【NPC】" "/tmp 占用前几名: `du -sk /tmp/* 2>/dev/null | sort -rn | head -5 | tr '\n' ' '`"
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

	# 进程起来后 2 秒内就退出 = 二进制多半是坏的(上次下载被断电/断网打断,
	# tar 解出半个文件但 -s 判断为"存在", 版本标记也已写入, 于是之后每次
	# 重启都以为"已下载过"而一直复用这个坏文件 —— 老逻辑只报"请检查配置",
	# 5 分钟一次的 cron 就永远原地打转)。这里删掉二进制和版本标记强制重下,
	# 再启动一次; 仍未活下来才认定是配置问题。
	if [ "`nvram get npc_enable`" != "1" ] ; then
		logger -t "【NPC】" "npc 未启用, 跳过重新下载"
		return 1
	fi
	logger -t "【NPC】" "npc 启动后立即退出, 怀疑二进制损坏, 删除 $NPC_BIN 后重新下载"
	npc_kill_wait
	rm -f $NPC_BIN $NPC_VER_FILE $NPC_BIN_DIR/npc.tar.gz 2>/dev/null
	rm -f /tmp/npc/npc /tmp/npc/npc.ver /tmp/npc/npc.tar.gz 2>/dev/null
	nvram set npc_ver=""
	if ! npc_ensure_bin ; then
		logger -t "【NPC】" "重新下载失败, 请检查网络(下次周期任务会再试)"
		return 1
	fi
	/etc/storage/npc_script.sh
	sleep 2
	npc_single_check
	if npc_alive ; then
		logger -t "【NPC】" "npc 重新下载后启动成功 (`pidof npc | wc -w` 个实例)"
		return 0
	fi
	logger -t "【NPC】" "npc启动失败, 请检查配置(服务器地址/vkey/服务端版本是否匹配)"
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
