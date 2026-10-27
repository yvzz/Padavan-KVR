# Padavan-KVR #

![](https://views.whatilearened.today/views/github/yvzz/Padavan-KVR.svg)[![](https://deepwiki.com/badge.svg)](https://deepwiki.com/yvzz/Padavan-KVR)

基于 [vb1980/Padavan-KVR](https://github.com/vb1980/Padavan-KVR.git) 固件（浅色主题）二次维护，最初 fork 自 [fightroad/Padavan-KVR](https://github.com/fightroad/Padavan-KVR.git)。

继承并整合了 hanwckf、chongshengB、padavanonly 的源码，主要特点：

1. 采用 padavanonly 源码的 5.0.4.0 无线驱动，支持 KVR（802.11k/v/r 漫游）
2. 整合 chongshengB 源码的插件体系，并在 Web 管理界面「自定义菜单」中新增了一批内网穿透 / 组网类插件
3. 部分优化来自 immortalwrt 的 Padavan 源码
4. 最近的更新代码来自 hanwckf 与 MeIsReallyBa 大佬的 4.4 内核分支
   - https://github.com/hanwckf/padavan-4.4
   - https://github.com/MeIsReallyBa/padavan-4.4

上游四位源码地址供参考：

- https://github.com/hanwckf/rt-n56u
- https://github.com/chongshengB/rt-n56u
- https://github.com/padavanonly/rt-n56u
- https://github.com/immortalwrt/padavan

## 默认登录与 WiFi 信息

管理地址

- `192.168.2.1`

管理账号 / 密码

- `admin` / `admin`

WiFi（默认 SSID 为机型名 `BOARD_PID`，**不带 MAC 后缀**）

- 2.4G：`机型名`，如 `K2P`
- 5G：`机型名_5G`，如 `K2P_5G`
- 访客：`机型名_GUEST` / `机型名_GUEST_5G`
- WiFi 密码：`1234567890`

> 早期版本 SSID 带 MAC 后四位（如 `K2P_9981`），现固件已改为纯机型名。若要恢复 MAC 后缀，在 `trunk/user/shared/defaults.h` 的 `DEF_WLAN_*_SSID` 定义中加 `MAC` 拼接并同步 `rc.c` 的填充逻辑。

## 支持的机型与编译配置

本仓库实际维护 **4 个机型**，均已配置 GitHub Actions 在线编译工作流（`.github/workflows/`）：

| 机型 | 工作流文件 | 内存 | /tmp 大小 | /etc 大小 |
|---|---|---|---|---|
| K2P | `K2P.yml` | 128M | 36M | 5M |
| MI-MINI | `MI-MINI.yml` | 128M | 36M | 5M |
| R2100 | `R2100.yml` | 256M | 48M | 13M |
| RM2100 | `RM2100.yml` | 256M | 48M | 13M |

> ⚠️ 对 7612 无线芯片的支持已知有问题，含 7612 的机型（如 B70）无法正常工作。

Fork 后可直接在 GitHub Actions 中选择机型编译，无需本地环境。自定义增减插件需编辑对应机型的 `.github/workflows/<机型>.yml`，修改 `echo "CONFIG_FIRMWARE_INCLUDE_XXX=y/n"` 行。

## 已编译插件清单

以下为四个工作流中**实际启用**（`=y`）的插件。Web 菜单中可能还存在其它未编译的开关项，那些仅代表 UI 骨架，不包含二进制。

### 四个机型全部编译（30 项）

**系统基础**

| 插件 | 说明 |
|---|---|
| DROPBEAR | SSH 服务端（Dropbear） |
| DROPBEAR_FAST_CODE | Dropbear 加速（对称加密/哈希优化） |
| OPENSSH | OpenSSH 客户端（与 Dropbear 共存） |
| OPENSSL_EC | OpenSSL 椭圆曲线支持 |
| OPENSSL_EXE | OpenSSL 命令行工具（证书生成等） |
| CURL | HTTP 客户端（插件下载依赖） |
| HTTPS | OpenSSL + HTTPS 支持 |
| DDNS_SSL | DDNS 客户端 HTTPS 支持 |
| TTYD | Web 终端 |
| HTOP | 系统进程监控 |
| NANO | 文本编辑器 |
| LRZSZ | 文件传输工具（rz/sz） |
| MSD_LITE | MSD Lite 工具 |

**网络 / QoS**

| 插件 | 说明 |
|---|---|
| XFRM | IPsec (XFRM) 内核模块 + iptables 扩展 |
| QOS | 网络 QoS 调度模块 |
| IMQ | IMQ 中间队列流量整形模块 |
| IFB | IFB 虚拟网络设备（流量整形） |
| NAPT66 | IPv6 NAT / 端口转发 |
| IPERF3 | 网络测速工具 |
| MTR | 网络诊断（traceroute + ping 结合） |
| TCPDUMP | 抓包工具 |
| SFTP | SFTP 服务器 |
| EAP_PEAP | EAP-PEAP 认证（企业级 WiFi） |

**组网 / 内网穿透**

| 插件 | 说明 |
|---|---|
| EASYTIER | P2P 虚拟局域网（Rust，二进制运行期下载） |
| NPC | nps 内网穿透客户端（二进制运行期下载） |
| VNTCLI | VNT 客户端（二进制运行期下载） |

**DNS / DDNS / 其它**

| 插件 | 说明 |
|---|---|
| ALIDDNS | 阿里云 DDNS |
| DDNSPOD | DNSPod DDNS |
| CLOUDFLARE | Cloudflare DDNS |
| BAFA | 巴法云（IoT / MQTT 推送） |

### 部分机型编译（按机型差异）

| 插件 | K2P | MI-MINI | R2100 | RM2100 | 说明 |
|---|:---:|:---:|:---:|:---:|---|
| WIREGUARD | ✅ | — | ✅ | ✅ | WireGuard VPN 内核模块 |
| TAILSCALE | ✅ | — | ✅ | ✅ | ZeroConfig 组网（WireGuard 系，二进制运行期下载） |
| VNTS | ✅ | — | ✅ | ✅ | VNT 服务端 |
| OPENVPN | ✅ | — | ✅ | ✅ | OpenVPN 客户端/服务端 |
| CADDY | ✅ | — | — | ✅ | 轻量 Web 服务器 / 文件管理（~4KB） |
| ALDRIVER | ✅ | — | — | ✅ | 阿里云盘 WebDAV |
| CIFS | ✅ | — | — | — | SMB/CIFS 客户端 |
| SMARTDNS | ✅ | — | ✅ | ✅ | 智能 DNS 分流 |
| DUMP1090 | ✅ | — | ✅ | ✅ | ADS-B 航班追踪（需 RTL_SDR） |
| FFMPEG_NEW | ✅ | — | ✅ | ✅ | ffmpeg 0.11.x（Minidlna/Firefly 依赖） |
| RTL_SDR | ✅ | — | ✅ | ✅ | RTL-SDR USB 接收器驱动 |
| SOCAT | ✅ | — | ✅ | ✅ | 多功能网络工具（socat） |
| SRELAY | ✅ | — | ✅ | ✅ | SOCKS5 代理 |
| XUPNPD | — | — | ✅ | ✅ | xUPnP IPTV 媒体服务器 |
| WXSEND | ✅ | ✅ | — | ✅ | 微信推送 |
| ADGUARDHOME | — | — | ✅ | ✅ | AdGuard Home DNS 广告过滤 |
| HDPARM | — | ✅ | ✅ | ✅ | 硬盘节能管理 |
| PARTED | — | ✅ | ✅ | ✅ | GPT 分区工具 |
| FTPD | — | ✅ | — | — | FTP 服务器 |
| SMBD | — | ✅ | — | — | Samba 文件共享服务器 |
| SMBD36 | — | ✅ | — | — | Samba 3.6（替代版） |
| LPRD | — | ✅ | — | — | LPR 打印机守护程序 |
| SERIAL | — | ✅ | — | — | USB-Serial 模块（如 pl2303） |
| U2EC | — | ✅ | — | — | USB-over-Ethernet 打印 |

### 未编译但代码在仓库中（可手动开启）

以下插件的源码存在于仓库中，Web 菜单有对应开关，但**当前工作流未编译**（`=n` 或被注释）。需要的话在对应机型的 `.yml` 中改为 `=y` 即可：

| 插件 | 说明 | 未编译原因 |
|---|---|---|
| FRPC / FRPS | frp 内网穿透 客户端/服务端 | 用户未选用 |
| NATPIERCE | 皎月连 NAT 穿透 | 用户未选用 |
| ZEROTIER | ZeroTier 组网 | 用户未选用 |
| TUNSAFE | WireGuard TCP 方式 | 用户未选用 |
| CLOUDFLARED | Cloudflare Tunnel | 用户未选用 |
| LUCKY | Lucky 管理面板 | 用户未选用 |
| ALIST | 网盘聚合 | 用户未选用 |
| VIRTUALHERE | USB 设备远程共享 | 用户未选用 |
| TRANSMISSION | BT 下载 | 体积较大 |
| ARIA / ARIA_WEB_CONTROL | Aria2 下载 | 体积较大 |
| MINIDLNA / FIREFLY | DLNA / iTunes 媒体服务器 | 用户未选用 |
| SHADOWSOCKS / V2RAY / XRAY / TROJAN / SSOBFS | 代理相关 | 运行期在线下载，无需集成 |

## 如何检查插件是否已编入固件

```sh
# 在路由器上查看二进制是否存在
ls /usr/bin/ | grep -iE "npc|easytier|tailscale"
ls /usr/sbin/ | grep -iE "openvpn|wireguard"
```

不存在 → 即使 Web「自定义菜单」里开关亮着也只是 UI 标记，不会凭空变出二进制。

## /tmp 与 /etc/storage 分区大小

分区大小在各机型的 workflow 中通过 `sed` 设置，按内存档次分档：

| 内存 | /tmp | /etc (storage) | 适用机型 |
|---|---|---|---|
| ≥256M | 48M | 13M | R2100、RM2100 |
| ≥128M | 36M | 5M | K2P、MI-MINI |
| 更小 | 24M | 4M | （预留） |

修改方法：编辑对应机型的 `.github/workflows/<机型>.yml`，搜索 `size_tmp` / `size_etc` / `mtd_part_size`。

⚠️ **storage 分区 + 固件大小必须小于闪存总大小，否则刷机变砖！** 计算方式：闪存总大小 − 编译后固件大小 = storage 可用上限。

## 个性化

修改背景图：刷机后在 `/etc/storage/` 新建 `bg` 文件夹，放入 `wood.jpg` 即可，路径为 `/etc/storage/bg/wood.jpg`。

修改 LOGO：替换 `trunk/user/www/n56u_ribbon_fixed/bootstrap/img/asus_logo.png`（像素 150×70）。

修改默认管理地址 / WiFi 名称 / 账号密码：见 `trunk/user/shared/defaults.h`。

## 编译

本地编译方法同其他 Padavan 源码（需先构建 toolchain）。推荐使用 `.github/workflows/` 下的在线工作流，fork 仓库后在 Actions 中选择机型即可编译，无需本地环境。
