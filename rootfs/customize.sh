#!/bin/bash
# rootfs 定制：由 build.sh 作为 mmdebstrap 的 --customize-hook 调用（root 模式，$1 是 chroot 目录，/proc、/sys、/dev
# 已由 mmdebstrap 挂好，包都已装完、服务启动被 policy-rc.d 拦住）。之后 mmdebstrap 再清掉 apt 列表与缓存、
# /tmp、/run，并把 /etc/machine-id 写成空文件（每台 VM 首次启动时各自生成）。
#
# 环境变量（build.sh 导出）：VMIMAGE_VERSION（镜像版本）、VMIMAGE_DIR（配方仓库根目录）。
set -euo pipefail

root=${1:?用法：customize.sh <chroot 目录>}
: "${VMIMAGE_VERSION:?}" "${VMIMAGE_DIR:?}"
overlay=$VMIMAGE_DIR/rootfs/overlay

in_root() { chroot "$root" "$@"; }

# ---- 覆盖文件：逐个列出权限，不依赖检出时的文件模式；overlay 里多出没列的文件就报错 ----
overlay_files=(
	"0644 etc/apt/sources.list.d/ubuntu.sources"
	"0644 etc/chrony/chrony.conf"
	"0644 etc/default/locale"
	"0644 etc/docker/daemon.json"
	"0644 etc/fstab"
	"0644 etc/hosts"
	"0644 etc/ssh/ssh_known_hosts"
	"0644 etc/ssh/sshd_config.d/10-llmgate-vm.conf"
	"0440 etc/sudoers.d/90-llmgate-vm"
	"0644 etc/systemd/journald.conf.d/llmgate-vm.conf"
	"0755 usr/lib/llmgate-vm/init"
	"0755 usr/lib/llmgate-vm/setup"
	"0644 usr/lib/systemd/system/llmgate-vm-init.service"
	"0644 usr/lib/systemd/system/llmgate-vm-setup.service"
	"0644 usr/lib/systemd/system/chrony.service.d/llmgate-vm.conf"
	"0644 usr/lib/systemd/system/containerd.service.d/llmgate-vm.conf"
	"0644 usr/lib/systemd/system/docker.service.d/llmgate-vm.conf"
	"0644 usr/lib/systemd/system/llmgate-devd.service.d/llmgate-vm.conf"
	"0644 usr/lib/systemd/system/ssh.service.d/llmgate-vm.conf"
	"0755 usr/lib/systemd/system-shutdown/llmgate"
)
listed=$(for e in "${overlay_files[@]}"; do echo "${e#* }"; done | sort)
present=$(cd "$overlay" && find . -type f -printf '%P\n' | sort)
if [ "$listed" != "$present" ]; then
	echo "customize.sh：overlay 目录与清单不一致：" >&2
	diff <(echo "$listed") <(echo "$present") >&2 || true
	exit 1
fi
for e in "${overlay_files[@]}"; do
	mode=${e%% *} path=${e#* }
	install -D -o root -g root -m "$mode" "$overlay/$path" "$root/$path"
done

# apt：只留 overlay 的 ubuntu.sources（官方归档），去掉构建用的镜像源与 mmdebstrap 的 apt 选项。
rm -f "$root/etc/apt/sources.list" "$root/etc/apt/apt.conf.d/99mmdebstrap"
# dpkg 的文档裁剪（--dpkgopt）保留下来，VM 里之后装的包同样不带 man / info / 文档（copyright 除外）。
if [ -f "$root/etc/dpkg/dpkg.cfg.d/99mmdebstrap" ]; then
	mv -f "$root/etc/dpkg/dpkg.cfg.d/99mmdebstrap" "$root/etc/dpkg/dpkg.cfg.d/llmgate-vm-excludes"
fi

# ---- 用户 dev：uid/gid 1000、免密 sudo、docker 组；口令字段为 *（不能口令登录，也不算锁定账户） ----
in_root groupadd --gid 1000 dev
in_root useradd --uid 1000 --gid 1000 --home-dir /home/dev --no-create-home --shell /bin/bash \
	--groups sudo,docker dev
in_root usermod --password '*' dev
in_root visudo -c -q -f /etc/sudoers.d/90-llmgate-vm
# /home 是数据盘的挂载点：镜像里保持空目录。
install -d -o root -g root -m 0755 "$root/home"
find "$root/home" -mindepth 1 -delete

# ---- sshd：不留、不生成主机密钥 ----
rm -f "$root"/etc/ssh/ssh_host_*
# Ubuntu 24.04 缺省用 ssh.socket 按需拉起 sshd：那样 22 端口在数据盘准备好之前就能连上，vmd「22 端口可连即启动
# 完成」的判断会提前成立。改为常驻的 ssh.service，排在 llmgate-vm-init 之后。
systemctl --root="$root" disable ssh.socket >/dev/null 2>&1 || true
systemctl --root="$root" enable ssh.service
# 有的发行版带启动时补生成主机密钥的单元，这里一律屏蔽（Ubuntu 24.04 本身没有）。
for u in sshd-keygen.service sshd-keygen@.service ssh-keygen.service; do
	if [ -e "$root/usr/lib/systemd/system/$u" ] || [ -e "$root/lib/systemd/system/$u" ]; then
		systemctl --root="$root" mask "$u"
	fi
done
if grep -rlsE '(^|[^-])ssh-keygen +-A' "$root/usr/lib/systemd" "$root/etc/systemd" >/dev/null; then
	echo "customize.sh：有 systemd 单元会在启动时生成 SSH 主机密钥" >&2
	exit 1
fi

# ---- 服务 ----
# 没有图形界面：缺省目标用 multi-user.target（Ubuntu 缺省是 graphical.target）。
systemctl --root="$root" set-default multi-user.target
systemctl --root="$root" enable llmgate-vm-init.service llmgate-vm-setup.service chrony.service
# 网卡由内核按 ip= 配好：不要任何网络管理器接手（networkd 没有配置时本不动网卡，屏蔽它免得以后装的包带进配置）。
systemctl --root="$root" mask systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service \
	systemd-resolved.service systemd-timesyncd.service
# Docker 装好但缺省不启用（sudo systemctl enable --now docker 即可用，数据目录在数据盘 /home/.docker-data）。
systemctl --root="$root" disable docker.service docker.socket containerd.service >/dev/null 2>&1 || true

# ---- 主机名、DNS、machine-id：都在启动时按 VM 设置，镜像里不带构建机的值 ----
rm -f "$root/etc/hostname"
rm -f "$root/etc/resolv.conf"
printf '%s\n' "# llmgate-vm-init 启动时按内核命令行 ip= 写入 DNS。" >"$root/etc/resolv.conf"
chmod 0644 "$root/etc/resolv.conf"

# ---- 登录提示：Ubuntu 的动态 motd 脚本不跑（终端首屏只留 shell） ----
if [ -d "$root/etc/update-motd.d" ]; then
	find "$root/etc/update-motd.d" -type f -exec chmod a-x {} +
fi

# ---- 版本标记（形状检查按字节扫描认出版本，仿固件的 lgfw1） ----
printf 'lgvm1{%s|}lgvm1\n' "$VMIMAGE_VERSION" >"$root/etc/llmgate-vm-release"
chmod 0644 "$root/etc/llmgate-vm-release"
install -d -o root -g root -m 0755 "$root/var/lib/llmgate-vm" "$root/var/log/llmgate-vm"

# ---- 瘦身 ----
rm -rf "$root"/var/lib/apt/lists/* "$root"/var/cache/debconf/*-old "$root"/var/log/*.log "$root"/var/log/apt/* \
	"$root"/var/lib/dpkg/*-old
find "$root/var/log" -type f \( -name '*.gz' -o -name '*.[0-9]' \) -delete
