#!/usr/bin/env bash
# 把 bin/<版本>/release/ 原样发布成本仓库 tag <版本> 上的 GitHub Release（流程见 docs/maintenance.md「发布」）。
#
#   GH_TOKEN=… make publish VERSION=<版本>
#
# 前置（脚本逐项核对，不满足即停）：
#   - 版本是 YYMMDDHHMM-xxxx（不带 -d），产物目录里 release/SHA256SUMS 全部核对通过，image.json 的版本一致、rootfs 来自快照；
#   - 本地有 tag <版本>，其提交七位短哈希的末四位就是版本的 xxxx，且远端 origin 上的同名 tag 指向同一提交；
#   - 令牌从环境变量 GH_TOKEN（或 GITHUB_TOKEN）读，需要本仓库 contents 写权限；只写进 0600 临时文件交给 curl，
#     不进命令行参数、不打印。
#
# 同一版本不重复发布：Release 不存在就新建；已存在（上次上传中断）只补传缺的 asset，同名 asset 长度或摘要不一致即停，
# 不覆盖。Release 说明由 image.json 生成。
set -euo pipefail

REPO=llm-net/llm-gate-vm-image
API=https://api.github.com/repos/$REPO
UPLOAD=https://uploads.github.com/repos/$REPO

die() { echo "publish: $*" >&2; exit 1; }
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VERSION=${1:-}
[[ $VERSION =~ ^[0-9]{10}-[0-9a-f]{4}$ ]] || die "版本须是 YYMMDDHHMM-xxxx（-d 脏树版本不能发布）：${VERSION:-空}"
OUT=bin/$VERSION
REL=$OUT/release
[ -f "$REL/SHA256SUMS" ] && [ -f "$OUT/image.json" ] || die "没有 $REL/SHA256SUMS 或 $OUT/image.json：先 sudo make image VERSION=$VERSION"
command -v curl >/dev/null && command -v python3 >/dev/null && command -v git >/dev/null || die "需要 curl、python3、git"

# ---- 产物 ----
echo "==> 核对 $REL/SHA256SUMS"
(cd "$REL" && sha256sum -c --quiet SHA256SUMS) || die "release/ 里的文件与 SHA256SUMS 不符"
listed=$(cd "$REL" && awk '{ print $2 }' SHA256SUMS | sort)
present=$(cd "$REL" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' | sort)
[ "$listed" = "$present" ] || die "release/ 里有 SHA256SUMS 没列的文件，或列了的文件不在"
python3 -I - "$OUT/image.json" "$VERSION" <<'EOF' || die "image.json 与版本不符，或 rootfs 不是从快照构建的"
import json, sys
img = json.load(open(sys.argv[1]))
ok = img.get("version") == sys.argv[2] and img.get("source", {}).get("rootfs", {}).get("snapshot")
sys.exit(0 if ok else 1)
EOF

# ---- tag ----
echo "==> 核对 tag $VERSION"
commit=$(git rev-parse -q --verify "refs/tags/$VERSION^{commit}") || die "本地没有 tag $VERSION（在构建所用的提交上 git tag $VERSION）"
short=$(git rev-parse --short=7 "$commit")
[ "${short: -4}" = "${VERSION: -4}" ] || die "tag $VERSION 指向 $short，末四位与版本不符（版本须在同一提交上 make print-version 取得）"
remote=$(git ls-remote origin "refs/tags/$VERSION^{}" "refs/tags/$VERSION" | awk 'NR==1 { print $1 }')
[ -n "$remote" ] || die "origin 上没有 tag $VERSION：先 git push origin main $VERSION"
remote_commit=$(git ls-remote origin "refs/tags/$VERSION^{}" | awk '{ print $1 }')
[ "${remote_commit:-$remote}" = "$commit" ] || die "origin 上的 tag $VERSION 与本地指向不同的提交"

# ---- 令牌 ----
token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
[ -n "$token" ] || die "环境变量 GH_TOKEN（或 GITHUB_TOKEN）为空"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
chmod 0700 "$tmp"
(umask 077 && printf 'Authorization: Bearer %s\n' "$token" >"$tmp/auth")
unset token
gh_api() { # gh_api 方法 地址 [curl 参数…]：响应体写 $tmp/resp，回显 HTTP 状态码
	local method=$1 url=$2
	shift 2
	curl --proto '=https' --tlsv1.2 -sS -X "$method" -H @"$tmp/auth" -H 'Accept: application/vnd.github+json' \
		-H 'X-GitHub-Api-Version: 2022-11-28' -o "$tmp/resp" -w '%{http_code}' "$@" "$url"
}

# ---- Release ----
code=$(gh_api GET "$API/releases/tags/$VERSION")
case $code in
200) echo "==> Release $VERSION 已存在，只补传缺的 asset" ;;
404)
	echo "==> 新建 Release $VERSION"
	python3 -I - "$OUT/image.json" >"$tmp/create.json" <<'EOF'
import json, sys
img = json.load(open(sys.argv[1]))
v, k, r = img["version"], img["kernel"], img["rootfs"]
src = img["source"]
kver, fc, snap = k["linux_version"], src["kernel"]["config_base"]["firecracker"], src["rootfs"]["snapshot"]
body = f"""LLM Gate Firecracker guest image `{v}` (linux-amd64 / x86_64).

- Kernel: Linux {kver}, Firecracker {fc} guest configuration plus `kernel/llmgate.config`, unpatched; the upstream source is attached as `linux-{kver}.tar.xz`.
- Root filesystem: Ubuntu 24.04 (noble) from `snapshot.ubuntu.com` `{snap}`; package list in `rootfs.packages.txt`.
- LLM Gate devices install this image from the signed manifest `https://llm.net/updates/components/vm-image/stable.json`. Verify manual downloads with `sha256sum -c SHA256SUMS`.

| Asset | Bytes | SHA-256 |
|---|---|---|
| `{k["asset"]}` | {k["gz_size"]} | `{k["gz_sha256"]}` |
| `{r["asset"]}` | {r["gz_size"]} | `{r["gz_sha256"]}` |

---

LLM Gate Firecracker guest 镜像 `{v}`：Linux {kver} 内核（Firecracker {fc} guest 配置 + llmgate 片段，未打补丁，附上游源码）与 Ubuntu 24.04 rootfs（snapshot.ubuntu.com `{snap}`）。LLM Gate 设备按 llm.net 签名清单安装；手动下载请用 `SHA256SUMS` 核对。
"""
json.dump({"tag_name": v, "name": v, "body": body, "draft": False, "prerelease": False, "make_latest": "true"}, sys.stdout)
EOF
	code=$(gh_api POST "$API/releases" -H 'Content-Type: application/json' --data-binary @"$tmp/create.json")
	[ "$code" = 201 ] || die "新建 Release 失败（HTTP $code）：$(head -c 500 "$tmp/resp")"
	;;
*) die "查询 Release 失败（HTTP $code）：$(head -c 500 "$tmp/resp")" ;;
esac
release_id=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$tmp/resp")

# 已有 asset：名称 → 长度与摘要（GitHub 给 sha256:<hex>，没有时只比长度）。
list_assets() {
	local code
	code=$(gh_api GET "$API/releases/$release_id/assets?per_page=100")
	[ "$code" = 200 ] || die "列 asset 失败（HTTP $code）"
	python3 -I -c '
import json, sys
for a in json.load(open(sys.argv[1])):
    d = (a.get("digest") or "").removeprefix("sha256:")
    print(a["name"], a["size"], d or "-", a["state"])' "$tmp/resp" >"$tmp/assets"
}
list_assets

for f in $(cd "$REL" && ls); do
	path=$REL/$f
	size=$(stat -c %s "$path")
	read -r _ have_size have_digest have_state < <(awk -v n="$f" '$1 == n' "$tmp/assets") || true
	if [ -n "${have_size:-}" ]; then
		if [ "$f" = SHA256SUMS ]; then
			want_digest=$(sha256sum "$path" | cut -d' ' -f1)
		else
			want_digest=$(awk -v n="$f" '$2 == n { print $1 }' "$REL/SHA256SUMS")
		fi
		if [ "$have_state" = uploaded ] && [ "$have_size" = "$size" ] && { [ "$have_digest" = - ] || [ "$have_digest" = "$want_digest" ]; }; then
			echo "    已有 $f"
			unset have_size have_digest have_state
			continue
		fi
		die "Release 上已有 $f 但与本地不一致（长度 $have_size / 摘要 $have_digest / 状态 $have_state）；不覆盖，人工确认后处理"
	fi
	echo "    上传 $f（$size 字节）"
	code=$(gh_api POST "$UPLOAD/releases/$release_id/assets?name=$f" -H 'Content-Type: application/octet-stream' \
		-T "$path" --retry 2)
	[ "$code" = 201 ] || die "上传 $f 失败（HTTP $code）：$(head -c 500 "$tmp/resp")"
done

# ---- 复核 ----
list_assets
want=$(cd "$REL" && ls | sort)
got=$(awk '$4 == "uploaded" { print $1 }' "$tmp/assets" | sort)
[ "$want" = "$got" ] || die "Release 上的 asset 与 release/ 不一致：
$(diff <(echo "$want") <(echo "$got") || true)"
echo "==> 完成：https://github.com/$REPO/releases/tag/$VERSION"
echo "    下一步：make manifest-entry VERSION=$VERSION，把条目交给 LLM Gate 主仓签名部署（docs/maintenance.md）"
