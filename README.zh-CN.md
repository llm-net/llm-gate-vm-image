# LLM Gate VM 镜像

[English](README.md) | **简体中文**

[LLM Gate](https://github.com/llm-net/llm-gate) 的 Firecracker 节点所用的 guest 镜像。LLM Gate 为 VM 工作空间建的每台 microVM 都从这里的镜像启动：一个 Linux 内核加一个 Ubuntu 24.04 根文件系统，只有 x86-64。

一般不需要手动下载。LLM Gate 设备先验证 `https://llm.net/updates/components/vm-image/stable.json` 签名清单，再把清单列出的精确 asset 装到 Firecracker 节点上，解压前后都核对长度与 SHA-256。设备不跟随「latest」Release。

## Release

每个 Release 的 tag 就是镜像版本（`YYMMDDHHMM-xxxx`，与固件同一格式，不带 `v`），指向构建它的配方。asset：

| asset | 内容 |
|---|---|
| `vmlinux-<版本>-x86_64.gz` | Linux 内核，未压缩的 ELF，再经 gzip |
| `rootfs-<版本>-x86_64.ext4.gz` | Ubuntu 24.04 根文件系统（ext4 整盘），再经 gzip |
| `image.json` | 版本、平台，两部分解压前后的长度与 SHA-256 |
| `kernel.config` | 实际编译用的完整内核配置 |
| `rootfs.packages.txt` | 根文件系统里每个包的版本、源码包与源码版本 |
| `SOURCES.txt` | 许可证与源码来源 |
| `linux-<内核版本>.tar.xz` | 未改动的上游内核源码 |
| `SHA256SUMS` | 其余 asset 的 SHA-256 |

下载后用 `sha256sum -c SHA256SUMS` 核对。

## 构建

配方在 [`firmware/vmimage/`](firmware/vmimage/)，是 [llm-net/llm-gate](https://github.com/llm-net/llm-gate) 里同名目录的快照；其中的 README 说明内核配置、根文件系统以及 guest 与节点之间的约定，链到 `firmware/vmimage/` 之外的路径指 llm-net/llm-gate 仓库。

构建需要 Linux x86-64、root、约 10 GiB 空闲空间，能经 HTTPS 访问 `cdn.kernel.org` 与 `snapshot.ubuntu.com`。在 Ubuntu 24.04 上：

```sh
sudo apt-get install --no-install-recommends gcc make flex bison bc libelf-dev libssl-dev perl xz-utils \
  gzip python3 ca-certificates curl mmdebstrap ubuntu-keyring e2fsprogs openssh-client
sudo VERSION=<版本> firmware/vmimage/build.sh                  # 产物：firmware/bin/vmimage/<版本>/
sudo firmware/vmimage/boot-test.sh firmware/bin/vmimage/<版本>  # 开机冒烟测试，需要 /dev/kvm
```

内核版本与 SHA-256、Firecracker guest 配置、Ubuntu 快照时间点都钉在 `build.sh` 里，按某个 tag 重建得到同一份内核配置与同一套包版本。

## 许可证

- 配方（本仓库的文件）：[MIT](LICENSE)。
- Linux 内核：GPL-2.0-only。每个 Release 附未改动的上游源码与实际使用的配置。
- 根文件系统：各 Ubuntu 软件包按其自身许可证分发，原文在镜像内 `/usr/share/doc/<包>/copyright`；源码可按 `rootfs.packages.txt` 的源码包与版本从钉住的 `snapshot.ubuntu.com` 时间点取得。

## 反馈

本仓库**不接受外部贡献或 Pull Request**，PR 会自动关闭。反馈请使用 [LLM Gate Issues](https://github.com/llm-net/llm-gate/issues)，安全漏洞请按 [SECURITY.md](https://github.com/llm-net/llm-gate/blob/main/SECURITY.md) 私密报告。
