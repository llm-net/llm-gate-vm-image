#!/usr/bin/env bash
# 安装构建依赖（Ubuntu 24.04 x86-64，需要 root）：guest 内核编译（gcc、make、flex、bison、bc、libelf、libssl、perl、xz）、
# rootfs（mmdebstrap、Ubuntu 归档签名钥匙串、e2fsprogs 的 mke2fs -d、核对预置主机公钥的 ssh-keygen）、制品打包
# （gzip、python3）与开机测试（iproute2、curl）。按包名逐个核对是否已装，只补缺的；可重复执行。
#
#   sudo make deps
set -euo pipefail

[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo "只支持 Linux x86-64" >&2; exit 1; }
[[ $(id -u) == 0 ]] || { echo "需要 root（apt-get install）" >&2; exit 1; }
command -v dpkg-query >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1 ||
	{ echo "只支持 Debian 系（建议 Ubuntu 24.04）" >&2; exit 1; }

pkgs=()
for p in gcc make flex bison bc libelf-dev libssl-dev perl xz-utils gzip python3 ca-certificates curl \
	mmdebstrap ubuntu-keyring e2fsprogs openssh-client iproute2 util-linux git; do
	dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || pkgs+=("$p")
done
if ((${#pkgs[@]})); then
	export DEBIAN_FRONTEND=noninteractive
	apt-get install -y --no-install-recommends "${pkgs[@]}" >/dev/null 2>&1 ||
		{ apt-get update >/dev/null && apt-get install -y --no-install-recommends "${pkgs[@]}" >/dev/null; }
	echo "apt: 装好 ${pkgs[*]}"
else
	echo "apt: 构建依赖已齐"
fi
