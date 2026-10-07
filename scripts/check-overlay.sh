#!/usr/bin/env bash
# 不需要 root 的配方自查：rootfs/customize.sh 里逐个写明权限的 overlay 清单必须与 rootfs/overlay/ 下的文件一一对应
# （构建时 customize.sh 在 chroot 里也做同样的核对，这里提前在本地发现）；packages.txt 不能有重复项。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

listed=$(sed -nE 's/^[[:space:]]*"0[0-7]{3} ([^"]+)"$/\1/p' rootfs/customize.sh | sort)
present=$(cd rootfs/overlay && find . -type f -printf '%P\n' | sort)
if [ "$listed" != "$present" ]; then
	echo "check-overlay: rootfs/customize.sh 的 overlay_files 与 rootfs/overlay/ 不一致：" >&2
	diff <(echo "$listed") <(echo "$present") >&2 || true
	exit 1
fi

dups=$(sed -e 's/#.*//' rootfs/packages.txt | xargs -n1 | sort | uniq -d)
if [ -n "$dups" ]; then
	echo "check-overlay: rootfs/packages.txt 有重复的包：$dups" >&2
	exit 1
fi
echo "check-overlay: overlay $(wc -l <<<"$listed") 个文件、packages.txt $(sed -e 's/#.*//' rootfs/packages.txt | xargs -n1 | wc -l) 个包，一致"
