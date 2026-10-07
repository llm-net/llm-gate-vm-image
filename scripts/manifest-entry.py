#!/usr/bin/env python3
"""由构建产物 image.json 生成官网签名清单 /updates/components/vm-image/stable.json 的一个 releases[] 条目。

    make manifest-entry VERSION=<版本>
    python3 -I scripts/manifest-entry.py bin/<版本>/image.json [--published-at YYYY-MM-DD] [--check]

输出是条目草稿（JSON，打到 stdout），交给 LLM Gate 主仓把它加进 stable.json、递增 revision、更新 updatedAt 并重签
部署——签名私钥与官网只在主仓，本仓库不改清单（docs/maintenance.md「交给主仓：签名清单」）。

字段与设备侧 llm-net/llm-gate 的 firmware/internal/vmimage（Release / Part 与 validate）一一对应：两部分的地址只能是
本仓库 Release 上该版本的精确 asset，长度与 SHA-256 取自 image.json，内核许可证恒为 "GPL-2.0"。
--check 对两个 asset 与内核源码包发 HEAD，核对 Release 上确实存在且长度一致（需要联网，不下载）。
"""
import argparse
import datetime
import json
import re
import sys
import urllib.request

REPO = "llm-net/llm-gate-vm-image"
ASSET_PREFIX = "https://github.com/" + REPO + "/releases/download/"
VERSION_RE = re.compile(r"^[0-9]{10}-[0-9a-f]{4}$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
# 设备侧 vmimage.ComponentManagerVersion：镜像与节点之间的约定变到旧固件不认时才提高，并须先发带新管理器的固件。
MIN_COMPONENT_MANAGER = 1


def die(msg):
    print("manifest-entry: " + msg, file=sys.stderr)
    sys.exit(1)


def head_length(url):
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "llm-gate-vm-image/manifest-entry"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return int(resp.headers.get("Content-Length", "-1"))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image_json")
    ap.add_argument("--published-at", default=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"))
    ap.add_argument("--check", action="store_true", help="HEAD 核对 Release 上的 asset 存在且长度一致")
    args = ap.parse_args()

    with open(args.image_json, encoding="utf-8") as f:
        img = json.load(f)
    if img.get("schema") != "llmgate.vm-image-build/v1":
        die("不是 llmgate.vm-image-build/v1 的 image.json")
    version = img["version"]
    if not VERSION_RE.match(version):
        die("版本 %r 不能发布（须是 YYMMDDHHMM-xxxx，-d 脏树版本只用于本地测试）" % version)
    if img.get("platform") != "linux-amd64" or img.get("arch") != "x86_64" or img.get("format") != "gzip":
        die("平台、架构或打包形态不是 linux-amd64 / x86_64 / gzip")

    k, r = img["kernel"], img["rootfs"]
    for what, p in (("kernel", k), ("rootfs", r)):
        if not (SHA_RE.match(p["gz_sha256"]) and SHA_RE.match(p["sha256"])):
            die(what + " 的摘要不是小写 SHA-256")
    kernel_url = ASSET_PREFIX + version + "/vmlinux-" + version + "-x86_64.gz"
    rootfs_url = ASSET_PREFIX + version + "/rootfs-" + version + "-x86_64.ext4.gz"
    if k["asset"] != kernel_url.rsplit("/", 1)[1] or r["asset"] != rootfs_url.rsplit("/", 1)[1]:
        die("image.json 里的 asset 名与发布地址规则不符")
    kver = k["linux_version"]
    kernel_src = ASSET_PREFIX + version + "/linux-" + kver + ".tar.xz"

    src = img.get("source", {})
    fc = src.get("kernel", {}).get("config_base", {}).get("firecracker", "")
    snapshot = src.get("rootfs", {}).get("snapshot", "")
    if not snapshot:
        die("rootfs 不是从 snapshot.ubuntu.com 快照构建的（UBUNTU_MIRROR 构建不能发布）")

    entry = {
        "version": version,
        "platform": "linux-amd64",
        "packaging": "gzip",
        "kernel": {
            "artifactUrl": kernel_url,
            "artifactSha256": k["gz_sha256"],
            "sizeBytes": k["gz_size"],
            "unpackedSha256": k["sha256"],
            "unpackedSizeBytes": k["size"],
            "license": "GPL-2.0",
            "sourceUrl": kernel_src,
        },
        "rootfs": {
            "artifactUrl": rootfs_url,
            "artifactSha256": r["gz_sha256"],
            "sizeBytes": r["gz_size"],
            "unpackedSha256": r["sha256"],
            "unpackedSizeBytes": r["size"],
            "license": "Ubuntu 24.04 软件包各按其许可证（镜像内 /usr/share/doc/*/copyright）",
            "sourceUrl": "https://github.com/" + REPO + "/tree/" + version,
        },
        "minComponentManager": MIN_COMPONENT_MANAGER,
        "allowInstall": True,
        "allowUpdate": True,
        "blocked": False,
        "note": "LLM Gate 自建 Firecracker guest 镜像：Linux %s（Firecracker %s guest 配置 + llmgate 片段，未打补丁）"
        "与 Ubuntu 24.04 rootfs（snapshot.ubuntu.com %s）；只接受这两个精确 asset，节点核对 gzip 前后的长度与 SHA-256、"
        "内核 ELF 架构与 rootfs 的版本标记。" % (kver, fc, snapshot),
        "publishedAt": args.published_at,
    }

    if args.check:
        for url, want in ((kernel_url, k["gz_size"]), (rootfs_url, r["gz_size"]), (kernel_src, None)):
            try:
                got = head_length(url)
            except Exception as e:  # noqa: BLE001 — 报给人看，原样带上原因
                die("取不到 %s：%s" % (url, e))
            if want is not None and got != want:
                die("%s 的长度是 %d，image.json 记的是 %d" % (url, got, want))
            print("manifest-entry: ok %s（%d 字节）" % (url, got), file=sys.stderr)

    json.dump(entry, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
