#!/bin/sh

mount -t proc proc /proc
mount -t sysfs sysfs /sys
[ -d /proc/bus/usb ] && mount -t usbfs usbfs /proc/bus/usb

size_tmp="24M"
size_var="4M"
size_etc="6M"

# 按实际内存上调 /tmp: 运行期下载二进制的插件(EasyTier 约 9M、npc 约 16M)都落在
# /tmp, 24M 扣除日志后经常只剩 20M 上下, 刚好卡在临界值 —— 表现为"同一份好包
# 时好时坏"(解包写出残片)。tmpfs 是按需占用物理内存的, 上限调大不会立刻吃内存,
# 所以只按内存分档给一个安全上限, 不搞一刀切。
# 低端(如 64M 内存)设备保持原值, 避免把内存耗在空目录上。
# 用 tr 压空格 + 简单 BRE 取值, 不用 awk/[[:space:]] 量词:
# 设备上的 busybox 对部分正则写法直接匹配不到(取到空值), 会让内存分档静默失效。
mem_total=`sed -n 's/^MemTotal: *\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null | head -n1 | cut -d' ' -f1`
case "$mem_total" in
''|*[!0-9]*) mem_total=0 ;;
esac
if [ "$mem_total" -ge 200000 ] ; then
	# ≥256M(含 512M 的 R2100/RM2100)
	size_tmp="64M"
	size_var="8M"
elif [ "$mem_total" -ge 90000 ] ; then
	# ≥128M(K2P、小米mini 等主流机型)
	size_tmp="48M"
	size_var="6M"
fi

if [ "$1" == "-l" ] ; then
	size_tmp="16M"
	size_var="2M"
fi

mount -t tmpfs tmpfs /dev   -o size=8K
mount -t tmpfs tmpfs /etc   -o size=$size_etc,noatime
mount -t tmpfs tmpfs /home  -o size=1M
mount -t tmpfs tmpfs /media -o size=8K
mount -t tmpfs tmpfs /mnt   -o size=8K
mount -t tmpfs tmpfs /tmp   -o size=$size_tmp
mount -t tmpfs tmpfs /var   -o size=$size_var

# 强制生效并核对: 部分内核/busybox 组合会忽略上面的 size=(实测 /tmp 仍是 30M,
# 即 tmpfs 默认的"一半物理内存"), 挂载选项形同虚设。这里记下目标值, 由
# mtd_storage.sh fill 阶段(DISK 已就绪)再 remount 一次并把实际结果记进日志,
# 排障时能一眼看出 /tmp 上限到底是多少。
echo "$mem_total" > /tmp/.mem_total_kb 2>/dev/null
# 只留数字(MB), mtd_storage.sh 会补上单位; 写非数字会在那边被判为无效而跳过
echo "${size_tmp%M}" > /tmp/.size_tmp_target 2>/dev/null

mkdir /dev/pts
mount -t devpts devpts /dev/pts

ln -sf /etc_ro/mdev.conf /etc/mdev.conf
mdev -s

# create dirs
mkdir -p -m 777 /var/lock
mkdir -p -m 777 /var/locks
mkdir -p -m 777 /var/private
mkdir -p -m 700 /var/empty
mkdir -p -m 777 /var/lib
mkdir -p -m 777 /var/log
mkdir -p -m 777 /var/run
mkdir -p -m 777 /var/tmp
mkdir -p -m 777 /var/spool
mkdir -p -m 777 /var/lib/misc
mkdir -p -m 777 /var/state
mkdir -p -m 777 /var/state/parport
mkdir -p -m 777 /var/state/parport/svr_statue
mkdir -p -m 777 /tmp/var
mkdir -p -m 777 /tmp/hashes
mkdir -p -m 777 /tmp/modem
mkdir -p -m 777 /tmp/rc_notification
mkdir -p -m 777 /tmp/rc_action_incomplete
mkdir -p -m 700 /home/root
mkdir -p -m 700 /home/root/.ssh
mkdir -p -m 755 /etc/storage
mkdir -p -m 755 /etc/storage/bin
mkdir -p -m 755 /etc/ssl
mkdir -p -m 755 /etc/Wireless
mkdir -p -m 750 /etc/Wireless/RT2860
mkdir -p -m 750 /etc/Wireless/iNIC

# extract storage files
mtd_storage.sh load

touch /etc/resolv.conf

if [ -f /etc_ro/openssl.cnf ]; then
	cp -f /etc_ro/openssl.cnf /etc/ssl
fi

if [ -f /etc_ro/ca-certificates.crt ]; then
	ln -sf /etc_ro/ca-certificates.crt /etc/ssl/cert.pem
fi

# create symlinks
ln -sf /home/root /home/admin
ln -sf /proc/mounts /etc/mtab
ln -sf /etc_ro/ethertypes /etc/ethertypes
ln -sf /etc_ro/protocols /etc/protocols
ln -sf /etc_ro/services /etc/services
ln -sf /etc_ro/shells /etc/shells
ln -sf /etc_ro/profile /etc/profile
ln -sf /etc_ro/e2fsck.conf /etc/e2fsck.conf
ln -sf /etc_ro/ipkg.conf /etc/ipkg.conf

# tune linux kernel
echo 65536        > /proc/sys/fs/file-max
echo "1024 65535" > /proc/sys/net/ipv4/ip_local_port_range

# fill storage
mtd_storage.sh fill

# prepare ssh authorized_keys
if [ -f /etc/storage/authorized_keys ] ; then
	cp -f /etc/storage/authorized_keys /home/root/.ssh
	chmod 600 /home/root/.ssh/authorized_keys
fi

# setup htop default color
if [ -f /usr/bin/htop ]; then
	mkdir -p /home/root/.config/htop
	echo "color_scheme=6" > /home/root/.config/htop/htoprc
fi

# radio2 kick station rssi low
/sbin/radio2_kicksta &

# perform start script
if [ -x /etc/storage/start_script.sh ] ; then
	/etc/storage/start_script.sh
fi

