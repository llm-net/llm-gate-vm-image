#!/usr/bin/env bash
# 构建 Firecracker VM 镜像：guest 内核（vmlinux）与 rootfs（ext4），配方说明见 docs/design.md。
#
#   sudo make image                          # VERSION 由 Makefile 按本仓库的提交生成（make print-version）
#   sudo VERSION=<YYMMDDHHMM-xxxx> ./build.sh
#
# 产物落 $OUT（缺省 bin/<VERSION>/，gitignored），先写到 <OUT>.tmp、全部成功才换上：
#   vmlinux  vmlinux.gz  rootfs.ext4  rootfs.ext4.gz   镜像两部分（gzip -n）及解压后的原件
#   image.json            两部分压缩前后的长度与 SHA-256、版本与平台（签名清单的输入）
#   SHA256SUMS            目录里其余文件的 SHA-256
#   kernel.config         实际编译用的完整内核配置（GPL 的「所用配置」）
#   rootfs.packages.txt   rootfs 里的软件包：包名、版本、源码包与源码版本
#   SOURCES.txt           许可证与源码来源
#   release/              发布时原样上传的 asset（两部分按 Release 文件名命名的硬链接、上面几个说明文件、内核源码包）
# 下载缓存与构建树在 bin/.cache、bin/.work：可重复执行，内核增量编译，rootfs 每次从头建。
#
# 环境变量：
#   VERSION           必填，YYMMDDHHMM-xxxx（脏树构建带 -d）
#   OUT               产物目录
#   JOBS              内核编译并发，缺省 nproc
#   UBUNTU_SNAPSHOT   snapshot.ubuntu.com 的时间点，缺省用下面钉住的 UBUNTU_SNAPSHOT_PIN
#   UBUNTU_MIRROR     改用某个 HTTPS 镜像站的当前内容（不走快照，只为本地加快；产物如实记录来源）
#   ROOTFS_FREE_MIB   rootfs 在装好的内容之外留的空间，缺省 2048
#   VMIMAGE_OFFLINE=1 不联网复核 github.com / gitlab.com 的主机公钥（只核对本地钉住的指纹）
set -euo pipefail
# 经 `make image VERSION=…` 调用时，命令行变量会经 MAKEFLAGS 传给内核的 make，覆盖内核 Makefile 自己的 VERSION
# （uname -r 就成了 <镜像版本>.18.54）。这里断开与外层 make 的联系。
unset MAKEFLAGS MAKEOVERRIDES MFLAGS MAKELEVEL

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ---- 钉住的输入（升级时连同摘要一起改，见 docs/maintenance.md「升级」） ----
KERNEL_VERSION=6.18.54
# kernel.org 的 sha256sums.asc（Kernel.org checksum autosigner 签名，指纹 B8868C80BA62A1FFFAF5FDA9632D3A06589DA6B1）。
KERNEL_SHA256=9df30b02dd8102bbd0be52556288ef6889ddbe7f1ddb96fbf847d0becf3eacac
KERNEL_URL=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz
# kernel/ 下原样入库的 Firecracker 官方 guest 配置（v1.17.0 标签，提交 95f868c8…）。
FC_TAG=v1.17.0
FC_COMMIT=95f868c8e345b1cc8faccd1a3c910b4989dc3f58
FC_BASE_CONFIG=microvm-kernel-ci-x86_64-6.18.config
FC_BASE_CONFIG_SHA256=ba22401a0c7292a4c024ebcd10a562d4a1f1bfd2faed671406d3b159c0cf5215
FC_BASE_CONFIG_URL=https://raw.githubusercontent.com/firecracker-microvm/firecracker/$FC_TAG/resources/guest_configs/$FC_BASE_CONFIG
KERNEL_FRAGMENT=llmgate.config
UBUNTU_SUITE=noble
UBUNTU_SNAPSHOT_PIN=20260929T000000Z
UBUNTU_KEYRING=/usr/share/keyrings/ubuntu-archive-keyring.gpg
# rootfs/overlay/etc/ssh/ssh_known_hosts 必须恰好是这些主机公钥（主机名 + SHA256 指纹）。
KNOWN_HOSTS_FINGERPRINTS=(
	"github.com SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
	"github.com SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM"
	"github.com SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s"
	"gitlab.com SHA256:eUXGGm1YGsMAS7vkcx6JOJdOGHPem5gQp4taiCfCLB8"
	"gitlab.com SHA256:HbW3g8zUjNSksFbqTiUWPWg2Bq1x8xdGUrliXFzSnUw"
	"gitlab.com SHA256:ROQFvPThGrW4RuWLoL9tq9I9zJ42fK4XywyRtbOz/EQ"
)
KNOWN_HOSTS=$HERE/rootfs/overlay/etc/ssh/ssh_known_hosts

die() { echo "vmimage: $*" >&2; exit 1; }
t0=$SECONDS
step() { printf '\n==> [%4ds] %s\n' "$((SECONDS - t0))" "$*"; }

# ---- 前置检查 ----
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die "只支持在 Linux x86-64 上构建"
[[ $(id -u) == 0 ]] || die "需要 root（mmdebstrap 的 root 模式与 mke2fs -d 保留属主）"
VERSION=${VERSION:-}
[[ $VERSION =~ ^[0-9]{10}-[0-9a-f]{4}(-d)?$ ]] || die "VERSION 必须是 YYMMDDHHMM-xxxx 形状（当前：${VERSION:-空}）"
for c in curl sha256sum tar xz gzip make gcc flex bison bc perl mmdebstrap mke2fs e2fsck python3 ssh-keygen flock; do
	command -v "$c" >/dev/null 2>&1 || die "缺少 $c：先运行 sudo make deps"
done
[ -f /usr/include/libelf.h ] || die "缺少 libelf 头文件：先运行 sudo make deps"
[ -f /usr/include/openssl/ssl.h ] || die "缺少 libssl 头文件：先运行 sudo make deps"
[ -f "$UBUNTU_KEYRING" ] || die "缺少 $UBUNTU_KEYRING（ubuntu-keyring）"

# 镜像内的时间戳与内核构建时间都取版本号里的时刻（与固件一样按构建机本地时区解读），同一 VERSION 的产物尽量一致。
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
	SOURCE_DATE_EPOCH=$(date -d "20${VERSION:0:2}-${VERSION:2:2}-${VERSION:4:2} ${VERSION:6:2}:${VERSION:8:2}" +%s) ||
		die "VERSION 里的时刻无效：$VERSION"
fi
export SOURCE_DATE_EPOCH

BASE=$HERE/bin
OUT=$(realpath -m "${OUT:-$BASE/$VERSION}")
CACHE=$BASE/.cache
WORK=$BASE/.work
JOBS=${JOBS:-$(nproc)}
ROOTFS_FREE_MIB=${ROOTFS_FREE_MIB:-2048}
[[ $ROOTFS_FREE_MIB =~ ^[0-9]+$ ]] || die "ROOTFS_FREE_MIB 必须是整数"
mkdir -p "$BASE" "$CACHE/debs" "$WORK"

# 同一台机器上同时只跑一个构建（共用缓存与构建树）。
exec 9>"$BASE/.lock"
flock -n 9 || die "另一个 vmimage 构建正在进行（$BASE/.lock）"

STAGE=$OUT.tmp
rm -rf "$STAGE"
mkdir -p "$STAGE"
trap 'rc=$?; [ $rc -eq 0 ] || { rm -rf "$STAGE"; echo "vmimage: 构建失败（退出码 $rc）" >&2; }' EXIT

# fetch URL 目标 SHA-256：已缓存且摘要对得上就不再下载；只走 HTTPS，摘要不对就删掉并失败。
fetch() {
	local url=$1 dest=$2 sum=$3
	if [ -f "$dest" ] && echo "$sum  $dest" | sha256sum -c --quiet >/dev/null 2>&1; then
		return 0
	fi
	rm -f "$dest.part"
	curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 30 -o "$dest.part" "$url"
	if ! echo "$sum  $dest.part" | sha256sum -c --quiet >/dev/null 2>&1; then
		rm -f "$dest.part"
		die "摘要不符：$url"
	fi
	mv -f "$dest.part" "$dest"
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# ======================= 内核 =======================
build_kernel() {
	step "内核 Linux $KERNEL_VERSION：取源码并核对 SHA-256"
	local tarball=$CACHE/linux-$KERNEL_VERSION.tar.xz
	fetch "$KERNEL_URL" "$tarball" "$KERNEL_SHA256"
	[ "$(sha256_of "$HERE/kernel/$FC_BASE_CONFIG")" = "$FC_BASE_CONFIG_SHA256" ] ||
		die "kernel/$FC_BASE_CONFIG 与钉住的 Firecracker $FC_TAG 原件不一致"

	local src=$WORK/linux-$KERNEL_VERSION obj=$WORK/kbuild-$KERNEL_VERSION
	if [ ! -f "$src/.llmgate-extracted" ]; then
		rm -rf "$src"
		tar -C "$WORK" -xf "$tarball"
		touch "$src/.llmgate-extracted"
	fi
	mkdir -p "$obj"

	step "内核配置：Firecracker $FC_TAG 的 $FC_BASE_CONFIG + $KERNEL_FRAGMENT → olddefconfig"
	# 与内核的 scripts/kconfig/merge_config.sh 一样：片段追加在后、同名项后者生效，再由 olddefconfig 解依赖。
	cat "$HERE/kernel/$FC_BASE_CONFIG" "$HERE/kernel/$KERNEL_FRAGMENT" >"$obj/.config"
	# 片段有意覆盖官方配置里的同名项，kconfig 对每一项的 override 提示不打印。
	local kconf_out
	kconf_out=$(make -s --no-print-directory -C "$src" O="$obj" olddefconfig 2>&1) || { echo "$kconf_out" >&2; die "olddefconfig 失败"; }
	grep -v 'override: reassigning to symbol' <<<"$kconf_out" >&2 || true
	# 片段里每一行都必须原样留在最终配置里：依赖没满足时 olddefconfig 会静默丢掉它。
	local line missing=0
	while IFS= read -r line; do
		[[ $line =~ ^CONFIG_[A-Z0-9_]+= ]] || continue
		if ! grep -qxF -- "$line" "$obj/.config"; then
			echo "vmimage: 最终配置里没有 $line（实际：$(grep -E "^(# )?${line%%=*}[= ]" "$obj/.config" || echo 未出现)）" >&2
			missing=1
		fi
	done <"$HERE/kernel/$KERNEL_FRAGMENT"
	[ $missing -eq 0 ] || die "内核配置片段没有全部生效"
	if grep -q '^CONFIG_MODULES=y' "$obj/.config" && grep -qE '^CONFIG_[A-Z0-9_]+=m$' "$obj/.config"; then
		echo "vmimage: 注意：配置里有编成模块（=m）的项，镜像不带模块，它们不可用：" >&2
		grep -E '^CONFIG_[A-Z0-9_]+=m$' "$obj/.config" | head -n 20 >&2
	fi

	step "内核编译（-j$JOBS）"
	# 可复现构建：固定构建时间、用户与主机名；源码不是 git 树且 LOCALVERSION 为空，uname -r 就是 $KERNEL_VERSION。
	KBUILD_BUILD_TIMESTAMP=$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S UTC') \
		KBUILD_BUILD_USER=llmgate KBUILD_BUILD_HOST=vmimage KBUILD_BUILD_VERSION=1 \
		make -s --no-print-directory -C "$src" O="$obj" -j"$JOBS" vmlinux
	local release
	release=$(cat "$obj/include/config/kernel.release")
	[ "$release" = "$KERNEL_VERSION" ] || die "内核自述版本是 $release，不是 $KERNEL_VERSION"

	cp "$obj/vmlinux" "$STAGE/vmlinux"
	cp "$obj/.config" "$STAGE/kernel.config"
	# Firecracker 在 x86-64 上引导未压缩的 ELF vmlinux：核对 ELF64、小端、EM_X86_64。
	python3 - "$STAGE/vmlinux" <<'EOF' || die "vmlinux 不是 x86-64 ELF"
import struct, sys
h = open(sys.argv[1], "rb").read(20)
ok = h[:4] == b"\x7fELF" and h[4] == 2 and h[5] == 1 and struct.unpack_from("<H", h, 18)[0] == 62
sys.exit(0 if ok else 1)
EOF
}

# ======================= rootfs =======================
check_known_hosts() {
	step "核对预置的 github.com / gitlab.com 主机公钥"
	local got want
	got=$(ssh-keygen -lf "$KNOWN_HOSTS" | awk '{ print $3, $2 }' | sort)
	want=$(printf '%s\n' "${KNOWN_HOSTS_FINGERPRINTS[@]}" | sort)
	[ "$got" = "$want" ] || die "ssh_known_hosts 与钉住的指纹不一致：
$got"
	if [ "${VMIMAGE_OFFLINE:-0}" = 1 ]; then
		echo "VMIMAGE_OFFLINE=1：跳过与官方来源的在线比对"
		return 0
	fi
	# github.com：官方 meta API 的 ssh_keys 必须与文件里 github.com 的三行逐字相同。
	# meta 响应有几百 KB（含 IP 段），落临时文件再读，不能当命令行参数传（单个参数上限 128 KiB）。
	local meta=$WORK/github-meta.json
	if curl --proto '=https' --tlsv1.2 -fsSL --max-time 30 -o "$meta" https://api.github.com/meta; then
		python3 - "$KNOWN_HOSTS" "$meta" <<'EOF' || die "github.com 主机公钥与 api.github.com/meta 不一致（官方可能已轮换，更新 ssh_known_hosts 与指纹）"
import json, sys
pinned = set()
for line in open(sys.argv[1]):
    f = line.split()
    if len(f) >= 3 and f[0] == "github.com":
        pinned.add(f[1] + " " + f[2])
official = set(json.load(open(sys.argv[2]))["ssh_keys"])
sys.exit(0 if pinned == official else 1)
EOF
		rm -f "$meta"
		echo "github.com：与 api.github.com/meta 一致"
	else
		echo "vmimage: 警告：取不到 api.github.com/meta，只按本地钉住的指纹核对 github.com" >&2
	fi
	# gitlab.com：官方文档页上必须列着钉住的三个指纹。
	local page fp
	if page=$(curl --proto '=https' --tlsv1.2 -fsSL --max-time 30 https://docs.gitlab.com/user/gitlab_com/); then
		for fp in "${KNOWN_HOSTS_FINGERPRINTS[@]}"; do
			[[ $fp == gitlab.com\ * ]] || continue
			grep -qF -- "${fp#gitlab.com }" <<<"$page" ||
				die "docs.gitlab.com 上没有 ${fp#gitlab.com }（官方可能已轮换，更新 ssh_known_hosts 与指纹）"
		done
		echo "gitlab.com：指纹与 docs.gitlab.com 一致"
	else
		echo "vmimage: 警告：取不到 docs.gitlab.com，只按本地钉住的指纹核对 gitlab.com" >&2
	fi
}

build_rootfs() {
	check_known_hosts

	local mirror snapshot=
	if [ -n "${UBUNTU_MIRROR:-}" ]; then
		[[ $UBUNTU_MIRROR == https://* ]] || die "UBUNTU_MIRROR 必须是 https:// 地址"
		mirror=${UBUNTU_MIRROR%/}
	else
		snapshot=${UBUNTU_SNAPSHOT:-$UBUNTU_SNAPSHOT_PIN}
		[[ $snapshot =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "UBUNTU_SNAPSHOT 必须形如 20260929T000000Z"
		mirror=https://snapshot.ubuntu.com/ubuntu/$snapshot
	fi
	ROOTFS_MIRROR=$mirror ROOTFS_SNAPSHOT=$snapshot

	local rootdir=$WORK/rootfs
	# 上次中断可能留下挂载：有就停下，不能 rm -rf 进 /proc、/sys。
	if findmnt -rn -o TARGET | grep -qE "^$rootdir(/|$)"; then
		die "$rootdir 下还有挂载（上次构建中断？），先手工卸载"
	fi
	rm -rf --one-file-system "$rootdir"

	local pkgs
	pkgs=$(sed -e 's/#.*//' "$HERE/rootfs/packages.txt" | xargs | tr ' ' ',')
	[ -n "$pkgs" ] || die "rootfs/packages.txt 是空的"
	local sign="[signed-by=$UBUNTU_KEYRING]"

	step "rootfs：mmdebstrap Ubuntu 24.04（$UBUNTU_SUITE，来源 $mirror）"
	export VMIMAGE_VERSION=$VERSION VMIMAGE_DIR=$HERE
	mmdebstrap \
		--mode=root \
		--variant=minbase \
		--architectures=amd64 \
		--include="$pkgs" \
		--aptopt='Acquire::Retries "5"' \
		--aptopt='Acquire::Languages "none"' \
		--dpkgopt='path-exclude=/usr/share/man/*' \
		--dpkgopt='path-exclude=/usr/share/info/*' \
		--dpkgopt='path-exclude=/usr/share/doc/*' \
		--dpkgopt='path-include=/usr/share/doc/*/copyright' \
		--dpkgopt='path-exclude=/usr/share/locale/*/LC_MESSAGES/*.mo' \
		--dpkgopt='path-exclude=/usr/share/lintian/*' \
		--dpkgopt='path-exclude=/usr/share/groff/*' \
		--skip=essential/unlink \
		--setup-hook='mkdir -p "$1"/var/cache/apt/archives/' \
		--setup-hook="sync-in '$CACHE/debs' /var/cache/apt/archives/" \
		--customize-hook="sync-out /var/cache/apt/archives '$CACHE/debs'" \
		--customize-hook="'$HERE/rootfs/customize.sh' \"\$1\"" \
		"$UBUNTU_SUITE" "$rootdir" \
		"deb $sign $mirror $UBUNTU_SUITE main universe" \
		"deb $sign $mirror $UBUNTU_SUITE-updates main universe" \
		"deb $sign $mirror $UBUNTU_SUITE-security main universe"
	grep -qxF "lgvm1{$VERSION|}lgvm1" "$rootdir/etc/llmgate-vm-release" || die "rootfs 里没有版本标记"
	dpkg-query --admindir="$rootdir/var/lib/dpkg" -W \
		-f='${binary:Package}\t${Version}\t${source:Package}\t${source:Version}\n' | sort >"$STAGE/rootfs.packages.txt"
	# .deb 缓存只留这次装进去的包（文件名 <包>_<版本，冒号写作 %3a>_<架构>.deb），旧版本不无限堆积。
	python3 - "$CACHE/debs" "$STAGE/rootfs.packages.txt" <<'EOF'
import os, sys, urllib.parse
cache, listing = sys.argv[1:]
keep = set()
for line in open(listing):
    pkg, ver = line.split("\t")[:2]
    keep.add((pkg.split(":")[0], ver))
for name in os.listdir(cache):
    parts = name[:-4].split("_") if name.endswith(".deb") else []
    if len(parts) == 3 and (parts[0], urllib.parse.unquote(parts[1])) not in keep:
        os.remove(os.path.join(cache, name))
EOF

	step "rootfs：生成 ext4"
	local used_mib size_mib uuid
	used_mib=$(du -s -x -B1M "$rootdir" | cut -f1)
	# 装好的内容 + 10% 的元数据余量 + ROOTFS_FREE_MIB，向上取整到 256 MiB。节点的 vmd 拷贝系统盘时一律把文件撑到
	# 16 GiB（稀疏，设备侧 firmware/internal/vmd 的 SystemDiskMinBytes），guest 每次启动在线 resize2fs 长满。
	size_mib=$(((used_mib + used_mib / 10 + ROOTFS_FREE_MIB + 255) / 256 * 256))
	# 文件系统 UUID 与目录哈希种子由版本号推出，同一 VERSION 的镜像不因随机数不同。
	uuid=$(printf 'llmgate-vm-rootfs %s' "$VERSION" | sha256sum | cut -c1-32 |
		sed -E 's/^(.{8})(.{4}).(.{3}).(.{3})(.{12})$/\1-\2-4\3-8\4-\5/')
	rm -f "$STAGE/rootfs.ext4"
	truncate -s "${size_mib}M" "$STAGE/rootfs.ext4"
	# 特性集写死（不随构建机的 mke2fs.conf 变）：经典 ext4 特性，不开 orphan_file / metadata_csum_seed。
	E2FSPROGS_FAKE_TIME=$SOURCE_DATE_EPOCH mke2fs -q -F -t ext4 -b 4096 -m 1 -L llmgate-root -U "$uuid" \
		-O none,has_journal,ext_attr,resize_inode,dir_index,filetype,extent,64bit,flex_bg,sparse_super,large_file,huge_file,dir_nlink,extra_isize,metadata_csum \
		-E "hash_seed=$uuid,root_owner=0:0" \
		-d "$rootdir" "$STAGE/rootfs.ext4" "${size_mib}M"
	e2fsck -f -n "$STAGE/rootfs.ext4" >/dev/null || die "rootfs.ext4 的 e2fsck 没过"
	echo "rootfs：内容 ${used_mib} MiB，镜像 ${size_mib} MiB"
	rm -rf --one-file-system "$rootdir"
}

# ======================= 打包 =======================
package() {
	step "压缩（gzip -9 -n）与摘要"
	gzip -9 -n -c "$STAGE/vmlinux" >"$STAGE/vmlinux.gz" &
	local p1=$!
	gzip -9 -n -c "$STAGE/rootfs.ext4" >"$STAGE/rootfs.ext4.gz" &
	local p2=$!
	wait $p1 && wait $p2 || die "gzip 失败"

	local mirror_note
	if [ -n "$ROOTFS_SNAPSHOT" ]; then
		mirror_note="Ubuntu 归档快照 $ROOTFS_SNAPSHOT（$ROOTFS_MIRROR）"
	else
		mirror_note="镜像站 $ROOTFS_MIRROR 构建时的内容（未走快照）"
	fi

	cat >"$STAGE/SOURCES.txt" <<EOF
LLM Gate VM 镜像 $VERSION（linux-amd64 / x86_64）的许可证与源码来源

内核 vmlinux
  Linux $KERNEL_VERSION，GPL-2.0-only（附 syscall 例外，见源码包 COPYING）。未打补丁。
  源码：$KERNEL_URL
        SHA-256 $KERNEL_SHA256
  配置：本目录 kernel.config（实际编译用的完整 .config）；由 Firecracker $FC_TAG 的 $FC_BASE_CONFIG
        （$FC_BASE_CONFIG_URL，提交 $FC_COMMIT，SHA-256 $FC_BASE_CONFIG_SHA256）
        叠加 LLM Gate 片段 kernel/$KERNEL_FRAGMENT 后经 make olddefconfig 得到。
  重建：tar xf linux-$KERNEL_VERSION.tar.xz && cp kernel.config linux-$KERNEL_VERSION/.config
        && make -C linux-$KERNEL_VERSION olddefconfig vmlinux

rootfs rootfs.ext4
  Ubuntu 24.04 LTS（$UBUNTU_SUITE）的二进制包，来源：$mirror_note。
  每个包按其自身许可证分发，许可证原文在镜像内 /usr/share/doc/<包名>/copyright。
  包清单（包名、版本、源码包、源码版本）见 rootfs.packages.txt；对应源码可从同一归档（快照）按源码包与版本取得，
  例如 apt-get source <源码包>=<源码版本>。
  LLM Gate 自己的定制（systemd 单元、脚本与配置）来自配方仓库的 rootfs/，以 MIT 公开：
  https://github.com/llm-net/llm-gate-vm-image/tree/$VERSION
EOF

	python3 - "$STAGE" "$VERSION" "$KERNEL_VERSION" "$KERNEL_URL" "$KERNEL_SHA256" "$FC_TAG" "$FC_BASE_CONFIG_URL" \
		"$FC_BASE_CONFIG_SHA256" "$ROOTFS_MIRROR" "$ROOTFS_SNAPSHOT" <<'EOF'
import hashlib, json, os, sys
stage, version, kver, kurl, ksha, fctag, fcurl, fcsha, mirror, snapshot = sys.argv[1:]

def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return os.path.getsize(path), h.hexdigest()

def part(raw, gz, asset):
    size, sha = digest(os.path.join(stage, raw))
    gz_size, gz_sha = digest(os.path.join(stage, gz))
    return {"file": gz, "asset": asset, "gz_size": gz_size, "gz_sha256": gz_sha, "size": size, "sha256": sha}

# asset 是 Release 上的文件名，与设备侧 llm-net/llm-gate 的 firmware/internal/vmimage KernelURL / RootfsURL 一致。
kernel = part("vmlinux", "vmlinux.gz", "vmlinux-" + version + "-x86_64.gz")
kernel.update({"linux_version": kver, "license": "GPL-2.0-only"})
rootfs = part("rootfs.ext4", "rootfs.ext4.gz", "rootfs-" + version + "-x86_64.ext4.gz")
rootfs.update({"distro": "Ubuntu 24.04 LTS (noble)", "license": "各软件包自身的许可证（镜像内 /usr/share/doc/*/copyright）"})
doc = {
    "schema": "llmgate.vm-image-build/v1",
    "version": version,
    "platform": "linux-amd64",
    "arch": "x86_64",
    "format": "gzip",
    "marker": "lgvm1{" + version + "|}lgvm1",
    "kernel": kernel,
    "rootfs": rootfs,
    "source": {
        "kernel": {"url": kurl, "sha256": ksha, "config": "kernel.config",
                   "config_base": {"firecracker": fctag, "url": fcurl, "sha256": fcsha},
                   "config_fragment": "kernel/llmgate.config"},
        "rootfs": {"archive": mirror, "snapshot": snapshot, "packages": "rootfs.packages.txt"},
    },
}
with open(os.path.join(stage, "image.json"), "w") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
    f.write("\n")
EOF

	(cd "$STAGE" && sha256sum vmlinux vmlinux.gz rootfs.ext4 rootfs.ext4.gz image.json kernel.config \
		rootfs.packages.txt SOURCES.txt >SHA256SUMS)

	# release/：发布时原样上传的全部 asset（硬链接，不另占空间）。两部分按设备侧 firmware/internal/vmimage 的 KernelURL / RootfsURL
	# 命名，另带内核源码包（GPL 的对应源码）。
	local rel=$STAGE/release f
	mkdir -p "$rel"
	ln "$STAGE/vmlinux.gz" "$rel/vmlinux-$VERSION-x86_64.gz"
	ln "$STAGE/rootfs.ext4.gz" "$rel/rootfs-$VERSION-x86_64.ext4.gz"
	for f in image.json kernel.config rootfs.packages.txt SOURCES.txt; do ln "$STAGE/$f" "$rel/$f"; done
	ln "$CACHE/linux-$KERNEL_VERSION.tar.xz" "$rel/" 2>/dev/null || cp "$CACHE/linux-$KERNEL_VERSION.tar.xz" "$rel/"
	(cd "$rel" && sha256sum -- * >SHA256SUMS)
}

build_kernel
build_rootfs
package

rm -rf "$OUT"
mv "$STAGE" "$OUT"
step "完成：$OUT"
ls -l "$OUT"
cat "$OUT/SHA256SUMS"
