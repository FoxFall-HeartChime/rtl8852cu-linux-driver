#!/bin/sh
# =============================================================================
# rtl8852cu 一键安装脚本
# Realtek RTL8852CU / RTL8832CU (AX3000 Wi-Fi 6 USB) Linux 驱动
#
#   sudo sh install.sh               有匹配的预编译包就用，否则本地编译
#   sudo sh install.sh --prebuilt    只用预编译包，没有就报错退出
#   sudo sh install.sh --build       强制本地编译
#   sudo sh install.sh --dkms        本地编译并注册 DKMS（换内核后自动重编）
#   sudo sh install.sh --uninstall   卸载
#
# 支持发行版：Alpine、Debian、Ubuntu，以及 CentOS/RHEL/Rocky/AlmaLinux/Fedora
#
# 安全约束：所有下载在请求前校验，仅允许 https，仅允许 GitHub 官方主机，
# 拒绝 localhost、环回、私有和保留地址。
# =============================================================================
set -eu

REPO=${REPO:-FoxFall-HeartChime/rtl8852cu-linux-driver}
MODULE=8852cu
PKG_VER=1.1
KREL=$(uname -r)
ARCH=$(uname -m)
MODULE_DIR=/lib/modules/$KREL/updates
BLACKLIST_FILE=/etc/modprobe.d/8852cu-no-rtw89.conf

MODE=auto          # auto | prebuilt | source
USE_DKMS=0
ACTION=install

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
	sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
	case $arg in
		--prebuilt)         MODE=prebuilt ;;
		--build|--source)   MODE=source ;;
		--dkms)             MODE=source; USE_DKMS=1 ;;
		--uninstall)        ACTION=uninstall ;;
		-h|--help)          usage; exit 0 ;;
		*)                  die "未知参数：$arg（用 --help 查看用法）" ;;
	esac
done

[ "$(id -u)" -eq 0 ] || die "需要 root 权限，请用 sudo sh $0 运行"

# RELEASE_TAG 会拼进下载地址，先限死字符集，避免构造出别的路径
if [ -n "${RELEASE_TAG:-}" ]; then
	case $RELEASE_TAG in
		*[!A-Za-z0-9._-]*) die "RELEASE_TAG 含非法字符：$RELEASE_TAG" ;;
	esac
fi

# 解包前先查条目，拒绝绝对路径和 ../ 跳出
safe_extract() {
	if tar -tzf "$1" 2>/dev/null | grep -q -e '^/' -e '\.\./'; then
		return 1
	fi
	tar -xzf "$1" -C "$2"
}

# -----------------------------------------------------------------------------
# 发行版识别
# -----------------------------------------------------------------------------
detect_family() {
	if [ -f /etc/alpine-release ]; then echo alpine; return 0; fi
	if [ -f /etc/debian_version ]; then echo debian; return 0; fi
	if [ -f /etc/redhat-release ]; then echo rhel; return 0; fi
	if [ -f /etc/os-release ]; then
		# shellcheck disable=SC1091
		. /etc/os-release
		case ${ID:-} in
			alpine)                                   echo alpine ;;
			debian|ubuntu|linuxmint|raspbian|kali)    echo debian ;;
			centos|rhel|rocky|almalinux|fedora|ol)    echo rhel ;;
			*)                                        echo unknown ;;
		esac
		return 0
	fi
	echo unknown
}

FAMILY=$(detect_family)
DISTRO=$FAMILY
if [ -f /etc/os-release ]; then
	# shellcheck disable=SC1091
	. /etc/os-release
	case ${ID:-} in
		ubuntu) DISTRO="Ubuntu ${VERSION_ID:-}" ;;
		debian) DISTRO="Debian ${VERSION_ID:-}" ;;
		alpine) DISTRO="Alpine $(cat /etc/alpine-release 2>/dev/null || echo '')" ;;
		centos|rhel|rocky|almalinux|fedora)
			DISTRO="${ID} ${VERSION_ID:-}" ;;
	esac
fi
log "系统：$DISTRO（$ARCH），内核：$KREL"

# -----------------------------------------------------------------------------
# URL 安全校验：scheme 限 https，host 限 GitHub 官方域名，拒绝 IP/环回/私有
# -----------------------------------------------------------------------------
allowed_host() {
	case $1 in
		github.com|api.github.com|raw.githubusercontent.com|\
		objects.githubusercontent.com|codeload.github.com|\
		release-assets.githubusercontent.com) return 0 ;;
		*) return 1 ;;
	esac
}

validate_url() {
	_url=$1
	case $_url in
		https://*) ;;
		http://*) die "拒绝非 https 地址：$_url" ;;
		*)        die "拒绝非 http(s) 地址：$_url" ;;
	esac
	_rest=${_url#https://}
	_hostport=${_rest%%/*}
	case $_hostport in
		*[!A-Za-z0-9.:-]*) die "拒绝异常主机名：$_hostport" ;;
	esac
	_host=${_hostport%%:*}
	case $_host in
		''|localhost|localhost.*|*.localhost) die "拒绝环回主机：$_host" ;;
		*:*) die "拒绝 IPv6 字面量：$_host" ;;
	esac
	case $_host in
		*[!0-9.]*) : ;;                      # 域名，继续白名单校验
		*) die "拒绝 IP 字面量：$_host" ;;    # 纯 IPv4 字面量
	esac
	allowed_host "$_host" || die "拒绝非 GitHub 主机：$_host"
}

# http_get <url> [输出文件]；无输出文件时写到 stdout
http_get() {
	validate_url "$1"
	if have curl; then
		if [ $# -ge 2 ]; then
			curl -fsSL --proto '=https' --proto-redir '=https' \
				--retry 2 --connect-timeout 15 --max-time 300 -o "$2" "$1"
		else
			curl -fsSL --proto '=https' --proto-redir '=https' \
				--retry 2 --connect-timeout 15 --max-time 300 "$1"
		fi
	elif have wget; then
		if [ $# -ge 2 ]; then
			wget -q -T 300 -O "$2" "$1"
		else
			wget -q -T 300 -O - "$1"
		fi
	else
		die "缺少 curl/wget，请先安装"
	fi
}

safe_name() { printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'; }

# -----------------------------------------------------------------------------
# 依赖安装
# -----------------------------------------------------------------------------
install_deps() {
	log "安装编译依赖"
	case $FAMILY in
		debian)
			export DEBIAN_FRONTEND=noninteractive
			apt-get update -qq
			apt-get install -y --no-install-recommends \
				build-essential bc bison flex libssl-dev libelf-dev \
				kmod curl ca-certificates >/dev/null
			if [ ! -e "/lib/modules/$KREL/build" ] && \
			   [ -z "$(ls -d /usr/src/linux-headers-* 2>/dev/null)" ]; then
				log "安装内核头文件 linux-headers-$KREL"
				apt-get install -y --no-install-recommends "linux-headers-$KREL" >/dev/null || \
				apt-get install -y --no-install-recommends linux-headers-generic >/dev/null || \
				apt-get install -y --no-install-recommends linux-headers-amd64 >/dev/null || \
				warn "未能自动安装内核头文件，请手动安装 linux-headers-$KREL"
			fi
			;;
		rhel)
			if have dnf; then PM=dnf; else PM=yum; fi
			$PM install -y gcc make bc bison flex openssl-devel \
				elfutils-libelf-devel kmod curl ca-certificates >/dev/null 2>&1 || \
				die "依赖安装失败，请检查软件源"
			if [ ! -e "/lib/modules/$KREL/build" ]; then
				log "安装内核开发包"
				$PM install -y "kernel-devel-$KREL" >/dev/null 2>&1 || \
				$PM install -y kernel-devel >/dev/null 2>&1 || \
				warn "未能自动安装 kernel-devel，请手动安装与 $KREL 匹配的版本"
			fi
			;;
		alpine)
			apk add --no-cache build-base bc bison flex openssl-dev \
				elfutils-dev kmod curl ca-certificates linux-headers >/dev/null
			if [ -z "$(ls -d /usr/src/linux-headers-* 2>/dev/null)" ]; then
				log "安装内核头文件"
				apk add --no-cache linux-lts-dev >/dev/null 2>&1 || \
				apk add --no-cache linux-virt-dev >/dev/null 2>&1 || \
				warn "未能自动安装内核头文件（linux-lts-dev），请确认内核类型"
			fi
			;;
		*)
			warn "未识别的发行版，跳过依赖安装，请自行准备 gcc/make/bc/flex/bison/内核头文件"
			;;
	esac
}

# -----------------------------------------------------------------------------
# 查找内核源码树
# -----------------------------------------------------------------------------
ensure_kmod() {
	have depmod && have modprobe && return 0
	log "安装 kmod（depmod/modprobe）"
	case $FAMILY in
		debian)
			export DEBIAN_FRONTEND=noninteractive
			apt-get update -qq
			apt-get install -y --no-install-recommends kmod >/dev/null || \
				die "kmod 安装失败"
			;;
		rhel)
			if have dnf; then dnf install -y kmod >/dev/null 2>&1; else yum install -y kmod >/dev/null 2>&1; fi || \
				die "kmod 安装失败"
			;;
		alpine)
			apk add --no-cache kmod >/dev/null || die "kmod 安装失败"
			;;
		*)
			warn "缺少 depmod/modprobe，请手动安装 kmod"
			;;
	esac
}

find_ksrc() {
	for d in "/lib/modules/$KREL/build" "/lib/modules/$KREL/source" \
	         /usr/src/linux-headers-* /usr/src/kernels/*; do
		if [ -f "$d/Makefile" ]; then echo "$d"; return 0; fi
	done
	return 1
}

proc_count() {
	nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2
}

# 读取 .ko 的 vermagic 内核版本（第一个字段）
ko_krel() {
	if have modinfo; then
		modinfo -F vermagic "$1" 2>/dev/null | awk '{print $1; exit}'
	else
		grep -a -o 'vermagic=[^ ]*' "$1" 2>/dev/null | head -n 1 | cut -d= -f2
	fi
}

# -----------------------------------------------------------------------------
# 安装 / 卸载
# -----------------------------------------------------------------------------
install_ko() {
	src=$1
	mkdir -p "$MODULE_DIR"
	cp -f "$src" "$MODULE_DIR/$MODULE.ko"
	chmod 644 "$MODULE_DIR/$MODULE.ko"
}

mask_in_kernel_driver() {
	# 6.19+ 主线内核自带 rtw89 的 8852cu 支持，会和本驱动抢同一个设备
	need_blacklist=0
	for m in rtw89_8852cu rtw89_usb; do
		if modinfo "$m" >/dev/null 2>&1; then
			need_blacklist=1
			modprobe -r "$m" 2>/dev/null || true
		fi
	done
	if [ "$need_blacklist" -eq 1 ]; then
		{
			echo "# rtl8852cu 外部驱动：屏蔽内核自带 rtw89 的 8852cu 支持"
			echo "blacklist rtw89_8852cu"
			echo "blacklist rtw89_usb"
		} > "$BLACKLIST_FILE"
		log "已屏蔽内核自带 rtw89 驱动"
	fi
}

load_and_check() {
	depmod -a "$KREL"
	modprobe -r "$MODULE" 2>/dev/null || true
	if ! modprobe "$MODULE"; then
		die "模块加载失败，请用 dmesg 查看原因"
	fi
	if lsmod 2>/dev/null | grep -q "^$MODULE "; then
		log "$MODULE 已加载"
	else
		warn "modprobe 返回成功但未在 lsmod 中看到 $MODULE"
	fi
	if have ip; then
		log "无线网卡接口："
		ip -o link 2>/dev/null | awk -F': ' '$2 ~ /^wl/ {print "    " $2}' || true
	fi
}

do_uninstall() {
	log "卸载 $MODULE"
	modprobe -r "$MODULE" 2>/dev/null || true
	if have dkms && dkms status 2>/dev/null | grep -q "^$MODULE/$PKG_VER"; then
		dkms remove -m "$MODULE" -v "$PKG_VER" --all || true
	fi
	rm -f "$MODULE_DIR/$MODULE.ko"
	rm -f "$BLACKLIST_FILE"
	depmod -a "$KREL" || true
	log "已卸载。若曾注册 DKMS，源码仍在 /usr/src/$MODULE-$PKG_VER"
}

# -----------------------------------------------------------------------------
# 预编译包
# -----------------------------------------------------------------------------
try_prebuilt() {
	asset="${MODULE}_$(safe_name "$KREL")_${ARCH}.tar.gz"
	if [ -n "${RELEASE_TAG:-}" ]; then
		url="https://github.com/$REPO/releases/download/$RELEASE_TAG/$asset"
	else
		url="https://github.com/$REPO/releases/latest/download/$asset"
	fi
	log "查找预编译包：$asset"
	tmp=$(mktemp -d)
	if ! http_get "$url" "$tmp/pkg.tar.gz" 2>/dev/null; then
		rm -rf "$tmp"
		return 1
	fi
	if ! safe_extract "$tmp/pkg.tar.gz" "$tmp" 2>/dev/null || [ ! -f "$tmp/$MODULE.ko" ]; then
		warn "预编译包内容异常"
		rm -rf "$tmp"
		return 1
	fi
	vm_krel=$(ko_krel "$tmp/$MODULE.ko")
	if [ "$vm_krel" != "$KREL" ]; then
		warn "预编译包内核版本不匹配（包 $vm_krel / 本机 $KREL）"
		rm -rf "$tmp"
		return 1
	fi
	install_ko "$tmp/$MODULE.ko"
	rm -rf "$tmp"
	log "已安装预编译模块：$asset"
	return 0
}

# -----------------------------------------------------------------------------
# 源码编译
# -----------------------------------------------------------------------------
prepare_source() {
	if [ -f "$SCRIPT_DIR/Makefile" ] && [ -f "$SCRIPT_DIR/common.mk" ]; then
		SRC=$SCRIPT_DIR
		log "使用本地源码：$SRC"
		return 0
	fi
	SRC=/usr/src/$MODULE-$PKG_VER
	log "下载驱动源码到 $SRC"
	tmp=$(mktemp -d)
	http_get "https://codeload.github.com/$REPO/tar.gz/refs/heads/main" "$tmp/src.tar.gz"
	rm -rf "$SRC"
	mkdir -p "$SRC"
	tar -xzf "$tmp/src.tar.gz" -C "$SRC" --strip-components=1
	rm -rf "$tmp"
}

build_source() {
	ksrc=$(find_ksrc) || die "找不到 $KREL 的内核源码/头文件，请先安装内核头文件"
	log "使用内核源码：$ksrc"
	( cd "$SRC" && make -j"$(proc_count)" KSRC="$ksrc" ) || die "编译失败"
	[ -f "$SRC/$MODULE.ko" ] || die "编译完成但未生成 $MODULE.ko"
	vm_krel=$(ko_krel "$SRC/$MODULE.ko")
	if [ "$vm_krel" != "$KREL" ]; then
		warn "编译出的模块针对 $vm_krel，本机内核是 $KREL，可能无法加载"
	fi
}

install_dkms() {
	log "注册 DKMS（$MODULE/$PKG_VER）"
	case $FAMILY in
		debian) apt-get install -y --no-install-recommends dkms >/dev/null ;;
		rhel)   have dnf && dnf install -y dkms >/dev/null 2>&1 || warn "请先安装 dkms" ;;
		alpine) apk add --no-cache dkms >/dev/null 2>&1 || die "Alpine 需要先安装 dkms" ;;
	esac
	have dkms || die "未找到 dkms"
	dst=/usr/src/$MODULE-$PKG_VER
	[ "$SRC" = "$dst" ] || {
		rm -rf "$dst"
		mkdir -p "$dst"
		( cd "$SRC" && tar -cf - . ) | ( cd "$dst" && tar -xf - )
	}
	dkms remove -m "$MODULE" -v "$PKG_VER" --all >/dev/null 2>&1 || true
	dkms add -m "$MODULE" -v "$PKG_VER" || die "dkms add 失败"
	dkms build -m "$MODULE" -v "$PKG_VER" || die "dkms build 失败"
	dkms install -m "$MODULE" -v "$PKG_VER" --force || die "dkms install 失败"
}

# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo /nonexistent)

if [ "$ACTION" = uninstall ]; then
	do_uninstall
	exit 0
fi

if [ "$FAMILY" = unknown ]; then
	warn "未识别的发行版，只尝试源码编译；如失败请手动安装依赖"
fi

ensure_kmod

installed=0
if [ "$MODE" != source ]; then
	if try_prebuilt; then
		installed=1
	elif [ "$MODE" = prebuilt ]; then
		die "没有 $KREL/$ARCH 的预编译包，去掉 --prebuilt 可本地编译"
	fi
fi

if [ "$installed" -eq 0 ]; then
	install_deps
	prepare_source
	build_source
	if [ "$USE_DKMS" -eq 1 ]; then
		install_dkms
	else
		install_ko "$SRC/$MODULE.ko"
	fi
fi

mask_in_kernel_driver
load_and_check

log "完成。开机自动加载可用：echo $MODULE > /etc/modules-load.d/$MODULE.conf"
[ -f /etc/modules-load.d/$MODULE.conf ] || {
	mkdir -p /etc/modules-load.d
	echo "$MODULE" > /etc/modules-load.d/$MODULE.conf
}
