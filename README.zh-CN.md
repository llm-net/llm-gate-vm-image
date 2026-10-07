# LLM Gate VM 镜像

[English](README.md) | **简体中文**

[LLM Gate](https://github.com/llm-net/llm-gate) Firecracker 节点所用的 guest 镜像及其构建配方。

LLM Gate 可以把一台 x86-64 Linux 主机纳管为 Firecracker 节点（节点上运行守护进程 `llmgate-vmd`），再在节点上为每个 VM 工作空间建一台独立的 microVM：开发工具、仓库与构建都在这台 VM 里跑，工作空间之间互不可见。每台 microVM 都从本仓库发布的镜像启动，镜像由两部分组成：

- **内核** `vmlinux`：Linux 6.18，Firecracker 在 x86-64 上直接引导的未压缩 ELF；
- **系统盘** `rootfs.ext4`：Ubuntu 24.04 最小系统加一套通用开发与创作工具。

一般不需要手动下载。LLM Gate 设备先验证 `https://llm.net/updates/components/vm-image/stable.json` 签名清单，再把清单列出的精确 asset 装到 Firecracker 节点上，解压前后都核对长度与 SHA-256、内核 ELF 架构与 rootfs 里的版本标记。设备不跟随「latest」Release，只认清单。

## 镜像内容

下列版本对应 Release `2610061825-da9f`；每个版本的完整包清单（包名、版本、源码包与源码版本）是该 Release 的 `rootfs.packages.txt`，实际内核配置是 `kernel.config`。

### 内核

| 项 | 内容 |
|---|---|
| 版本 | Linux 6.18.54，未打补丁 |
| 配置 | Firecracker v1.17.0 官方 guest 配置 `microvm-kernel-ci-x86_64-6.18.config` + [`kernel/llmgate.config`](kernel/llmgate.config) |
| 形态 | 功能全部编进内核，不带模块；`/proc/config.gz` 可读 |
| 设备 | virtio-blk（系统盘 `/dev/vda`、数据盘 `/dev/vdb`）、virtio-net（`eth0`）、vsock、KVM PTP 时钟 |
| 容器与网络 | cgroup v2、各类 namespace、overlayfs、bridge / veth / vxlan、nftables 与 iptables、IPVS、ipset、TUN、FUSE |
| 补充项 | SendCtrlAltDel 所需的 i8042 键盘、`BLK_DEV_WRITE_MOUNTED`（在线扩容）、k3s / kube-proxy 用到的 xtables 匹配与 IPVS 调度器 |
| 不含 | 嵌套 KVM、WireGuard、Btrfs、CIFS |

### 系统盘

Ubuntu 24.04 LTS（noble），`mmdebstrap --variant=minbase` 加 [`rootfs/packages.txt`](rootfs/packages.txt) 里的包，不装 Recommends；软件源钉在 `snapshot.ubuntu.com` 的时间点 `20260929T000000Z`，同一时间点重建得到同一套包版本。共 465 个包，内容约 1.3 GiB。man、info 与文档不装（保留各包的 `copyright`），这条规则留在镜像里，VM 里之后装的包同样裁剪。

| 类别 | 软件（版本） |
|---|---|
| 基础系统 | systemd / udev 255.4、dbus、kmod、iproute2、iputils-ping、procps、psmisc、tzdata、less、nano、vim-tiny、bash-completion、lsb-release |
| 包管理 | apt 2.8.3、ubuntu-keyring（VM 里 apt 指向 Ubuntu 官方归档） |
| 登录与权限 | openssh-server / openssh-client 9.6p1、sudo 1.9.15p5 |
| 开发 | git 2.43.0、tmux 3.4、build-essential（gcc / g++ 13.3、make 4.3）、python3 3.12.3 + python3-venv、perl 5.38、curl 8.5.0、wget、gnupg、jq 1.7.1、rsync、openssl 3.0.13 |
| 压缩与文件 | xz-utils、zstd、bzip2、zip / unzip、file |
| 创作工具 | ffmpeg 6.1.1、imagemagick 6.9.12、fontconfig + fonts-noto-cjk（中日韩字体） |
| 容器 | docker.io 29.1.3、containerd 2.2.1、runc 1.3.4——装好但缺省不启用，数据目录在数据盘 `/home/.docker-data` |
| 时间与磁盘 | chrony 4.5、e2fsprogs 1.47.0 |

**没有预装**：开发工具 CLI（Claude Code、Codex 等）、LLM Gate 的 `gate` 与 devd、Node.js、Go、`pip` 命令（只有 venv 自带的 wheel）、docker compose / buildx。它们由 LLM Gate 建立工作空间时装，或由仓库的 `.llmgate/setup.sh` 装。

### 预置配置

- **用户 `dev`**（uid / gid 1000）：不能用口令登录，免密 sudo，在 `docker` 组里。
- **sshd**：只认公钥，禁口令与 root 登录；唯一的主机密钥放在数据盘 `/home/.llmgate-vm/`，由 LLM Gate 设备生成，系统盘上不留、启动时也不生成；允许 TCP 与 Unix socket 转发，`MaxSessions 64`。
- **`/etc/ssh/ssh_known_hosts`**：预置 github.com 与 gitlab.com 的主机公钥，构建时与官方来源核对。
- **两块盘**：系统盘可整盘重建（apt 装的包、`/usr/local`、`/etc` 的改动随之丢失），数据盘挂在 `/home`，`$HOME`、Docker 数据与身份都在上面；两块盘每次启动在线扩容到实际大小。
- **网络**：由内核命令行 `ip=` 配好，networkd / resolved / timesyncd 都屏蔽；主机名与 DNS 启动时按 VM 写入。
- **时间**：chrony 优先跟宿主的 KVM PTP 时钟走，没有该设备时退回 `ntp.ubuntu.com`。
- **首次启动脚本**：工作空间仓库里有 `.llmgate/setup.sh` 时，系统盘首次启动（含重建后）以 `dev` 身份在后台跑一次，日志在 `/var/log/llmgate-vm/setup.log`。
- **关机**：`poweroff` 时经 vsock 通知节点；`reboot` 让 Firecracker 退出、由节点重新拉起。
- **版本标记**：`/etc/llmgate-vm-release` 一行 `lgvm1{<版本>|}lgvm1`。

启动顺序、数据盘布局与 guest 和节点之间的完整约定见 [docs/design.md](docs/design.md)。

## Release

每个 Release 的 tag 就是镜像版本（`YYMMDDHHMM-xxxx`，与 LLM Gate 固件同一格式，不带 `v`），指向构建它的配方提交。asset：

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

下载后用 `sha256sum -c SHA256SUMS` 核对。`2610061825-da9f` 的 tag 里配方在 `firmware/vmimage/` 目录下，此后的版本在仓库根目录。

## 构建

需要 Linux x86-64、root、约 10 GiB 空闲空间，能经 HTTPS 访问 `cdn.kernel.org` 与 `snapshot.ubuntu.com`；开机测试另需 `/dev/kvm`。在 Ubuntu 24.04 上：

```sh
sudo make deps                          # 构建依赖
make print-version                      # 取一次版本，后面每一步都显式传它
sudo make image VERSION=<版本>          # 产物：bin/<版本>/
sudo make boot-test VERSION=<版本>      # 开机冒烟测试
```

内核版本与 SHA-256、Firecracker guest 配置、Ubuntu 快照时间点都钉在 `build.sh` 里，按某个 tag 重建得到同一份内核配置与同一套包版本。构建细节见 [docs/design.md](docs/design.md)，发布与升级流程见 [docs/maintenance.md](docs/maintenance.md)。

## 许可证

- 配方（本仓库的文件）：[MIT](LICENSE)。
- Linux 内核：GPL-2.0-only。每个 Release 附未改动的上游源码与实际使用的配置。
- 根文件系统：各 Ubuntu 软件包按其自身许可证分发，原文在镜像内 `/usr/share/doc/<包>/copyright`；源码可按 `rootfs.packages.txt` 的源码包与版本从钉住的 `snapshot.ubuntu.com` 时间点取得。

## 反馈

本仓库**不接受外部贡献或 Pull Request**，PR 会自动关闭。反馈请使用 [LLM Gate Issues](https://github.com/llm-net/llm-gate/issues)，安全漏洞请按 [SECURITY.md](https://github.com/llm-net/llm-gate/blob/main/SECURITY.md) 私密报告。
