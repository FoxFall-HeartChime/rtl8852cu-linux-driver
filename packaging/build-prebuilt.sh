#!/bin/sh
# =============================================================================
# 在目标发行版环境里编译 8852cu 并打成预编译包
#
#   sh packaging/build-prebuilt.sh [输出目录]
#
# 由 .github/workflows/packages.yml 在各发行版容器里调用；也可以在本机直接跑
# （需要 root、能装依赖、有对应内核头文件）。
#
# 产物：
#   8852cu_<内核版本>_<架构>.tar.gz   install.sh 消费的通用包
#   8852cu_<内核版本>_<deb 架构>.deb  Debian/Ubuntu 原生包
# =============================================================================
set -eu

OUT=${1:-/out}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODULE=8852cu
WORK=${WORK:-/tmp/8852cu-build}

log() { printf '==> %s\n' "$*"; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

detect_family() {
	if [ -f /etc/alpine-release ]; then echo alpine; return 0; fi
	if [ -f /etc/debian_version ]; then echo debian; return 0; fi
	if [ -f /etc/redhat-release ]; then echo rhel; return 0; fi
	echo unknown
}

proc_count() {
	nproc 2>/dev/null || echo 2
}

safe_name() { printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'; }

install_deps() {
	log "安装编译依赖（$FAMILY）"
	case $FAMILY in
		debian)
			export DEBIAN_FRONTEND=noninteractive
			apt-get update -qq
			apt-get install -y --no-install-recommends \
				build-essential bc bison flex libssl-dev libelf-dev kmod \
				ca-certificates >/dev/null
			apt-get install -y --no-install-recommends linux-headers-generic >/dev/null 2>&1 || \
			apt-get install -y --no-install-recommends linux-headers-amd64 >/dev/null 2>&1 || \
			apt-get install -y --no-install-recommends linux-headers-"$(uname -r)" >/dev/null 2>&1 || \
			die "无法安装内核头文件"
			;;
		rhel)
			if have dnf; then PM=dnf; else PM=yum; fi
			$PM install -y gcc make bc bison flex openssl-devel \
				elfutils-libelf-devel kmod perl ca-certificates >/dev/null 2>&1 || \
				die "依赖安装失败"
			$PM install -y kernel-devel kernel-headers >/dev/null 2>&1 || \
				die "kernel-devel 安装失败"
			;;
		alpine)
			apk add --no-cache build-base bc bison flex openssl-dev \
				elfutils-dev kmod >/dev/null
			apk add --no-cache linux-lts-dev >/dev/null 2>&1 || \
			apk add --no-cache linux-virt-dev >/dev/null 2>&1 || \
			die "内核头文件安装失败"
			;;
		*)
			die "无法识别的发行版"
			;;
	esac
}

find_ksrc() {
	for d in /lib/modules/*/build /lib/modules/*/source \
	         /usr/src/linux-headers-* /usr/src/kernels/*; do
		if [ -f "$d/Makefile" ]; then echo "$d"; return 0; fi
	done
	return 1
}

krel_of() {
	if [ -f "$1/include/config/kernel.release" ]; then
		cat "$1/include/config/kernel.release"
	elif [ -f "$1/include/generated/utsrelease.h" ]; then
		sed -n 's/^#define UTS_RELEASE "\(.*\)"$/\1/p' \
			"$1/include/generated/utsrelease.h"
	else
		make -s -C "$1" kernelversion
	fi
}

ko_vermagic() {
	grep -a -o 'vermagic=[^ ]*' "$1" | head -n 1 | cut -d= -f2
}

deb_arch() {
	case $(uname -m) in
		x86_64)  echo amd64 ;;
		aarch64) echo arm64 ;;
		armv7l)  echo armhf ;;
		i?86)    echo i386 ;;
		*)       echo "$(uname -m)" ;;
	esac
}

distro_label() {
	if [ -f /etc/os-release ]; then
		# shellcheck disable=SC1091
		. /etc/os-release
		echo "${ID:-unknown}${VERSION_ID:+-$VERSION_ID}"
	else
		echo unknown
	fi
}

main() {
	FAMILY=$(detect_family)
	[ "$FAMILY" = unknown ] && die "无法识别的发行版"

	mkdir -p "$OUT"
	rm -rf "$WORK"
	mkdir -p "$WORK"
	log "复制源码到 $WORK"
	( cd "$ROOT" && tar -cf - . ) | ( cd "$WORK" && tar -xf - )

	install_deps

	KSRC=$(find_ksrc) || die "找不到内核源码树"
	KREL=$(krel_of "$KSRC")
	[ -n "$KREL" ] || die "无法确定内核版本"
	log "内核：$KREL"
	log "源码树：$KSRC"

	log "编译"
	if [ -f "$KSRC/Module.symvers" ]; then
		MODPOST_FLAG=""
	else
		MODPOST_FLAG="KBUILD_MODPOST_WARN=1"
		log "注意：$KSRC 没有 Module.symvers，符号解析检查降级为警告"
	fi
	# shellcheck disable=SC2086
	( cd "$WORK" && make -j"$(proc_count)" KSRC="$KSRC" $MODPOST_FLAG )
	[ -f "$WORK/$MODULE.ko" ] || die "未生成 $MODULE.ko"

	VERMAGIC=$(ko_vermagic "$WORK/$MODULE.ko")
	case $VERMAGIC in
		"$KREL"*) : ;;
		*) die "vermagic 不匹配：$VERMAGIC vs $KREL" ;;
	esac

	SAFE=$(safe_name "$KREL")
	ARCH=$(uname -m)

	PKGDIR="$WORK/pkg"
	mkdir -p "$PKGDIR"
	cp "$WORK/$MODULE.ko" "$PKGDIR/"
	cat > "$PKGDIR/META" <<EOF
module=$MODULE
kernel_release=$KREL
arch=$ARCH
vermagic=$VERMAGIC
distro=$(distro_label)
built=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
	tar -czf "$OUT/${MODULE}_${SAFE}_${ARCH}.tar.gz" -C "$PKGDIR" "$MODULE.ko" META
	log "已生成 $OUT/${MODULE}_${SAFE}_${ARCH}.tar.gz"

	if [ "$FAMILY" = debian ] && have dpkg-deb; then
		DEBARCH=$(deb_arch)
		# dpkg only accepts lowercase alnum plus '+', '-', '.', so the
		# kernel release (e.g. 6.12.57+deb13-amd64) needs its own mapping
		DEB_SAFE=$(printf '%s' "$KREL" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9+.-]/-/g; s/^[^a-z0-9]*//')
		DEBROOT="$WORK/debroot"
		mkdir -p "$DEBROOT/DEBIAN" \
		         "$DEBROOT/lib/modules/$KREL/updates"
		cp "$WORK/$MODULE.ko" "$DEBROOT/lib/modules/$KREL/updates/"
		cat > "$DEBROOT/DEBIAN/control" <<EOF
Package: $MODULE-modules-$DEB_SAFE
Version: ${PKG_VERSION:-1.1}
Architecture: $DEBARCH
Maintainer: FoxFall-HeartChime <344287043+FoxFall-HeartChime@users.noreply.github.com>
Section: kernel
Priority: optional
Installed-Size: 4096
Description: Realtek RTL8852CU (AX3000 Wi-Fi 6 USB) driver for kernel $KREL
 Out-of-tree module built from the rtl8852cu-linux-driver source tree.
EOF
		printf '#!/bin/sh\nset -e\ndepmod -a %s || true\n' "$KREL" \
			> "$DEBROOT/DEBIAN/postinst"
		printf '#!/bin/sh\nset -e\nmodprobe -r %s 2>/dev/null || true\n' "$MODULE" \
			> "$DEBROOT/DEBIAN/prerm"
		printf '#!/bin/sh\nset -e\ndepmod -a %s || true\n' "$KREL" \
			> "$DEBROOT/DEBIAN/postrm"
		chmod 755 "$DEBROOT/DEBIAN/postinst" \
		          "$DEBROOT/DEBIAN/prerm" \
		          "$DEBROOT/DEBIAN/postrm"
		dpkg-deb --build --root-owner-group "$DEBROOT" \
			"$OUT/${MODULE}_${SAFE}_${DEBARCH}.deb" >/dev/null
		log "已生成 $OUT/${MODULE}_${SAFE}_${DEBARCH}.deb"
	fi

	ls -l "$OUT"
}

main "$@"
