# 配方与 guest 契约

Firecracker 节点（守护进程 `llmgate-vmd`）上每台 microVM 都从本仓库构建的镜像启动。镜像分两部分：

- **内核** `vmlinux`：Linux 6.18 的未压缩 ELF（Firecracker 在 x86-64 上直接引导它），所需功能全部编进内核，不带模块。
- **rootfs** `rootfs.ext4`：Ubuntu 24.04 最小系统，作 VM 的系统盘（每台 VM 一份可写拷贝，可整盘替换）。

镜像与节点之间的约定（用户、身份目录、vsock 端口、版本标记、`setup.sh`）在设备侧以 LLM Gate 固件源码（llm-net/llm-gate）的
`firmware/internal/vmd/api.go`「guest 与节点之间的约定」为准，本仓库的配方照它实现；
下文「guest 契约」是镜像一侧的实现。构建、发布与升级的操作步骤见 [maintenance.md](maintenance.md)。

## 目录

| 路径 | 内容 |
|---|---|
| `Makefile` | 入口：`print-version`、`deps`、`image`、`boot-test`、`manifest-entry`、`publish`、`check` |
| `build.sh` | 构建入口：内核、rootfs、打包与摘要；钉住的上游版本与 SHA-256 都在文件开头 |
| `boot-test.sh` | 本机开机冒烟测试（Firecracker 官方整包，不经 jailer） |
| `kernel/microvm-kernel-ci-x86_64-6.18.config` | Firecracker v1.17.0 官方 guest 配置，**原样**入库（`resources/guest_configs/`，标签 `v1.17.0`，提交 `95f868c8e345b1cc8faccd1a3c910b4989dc3f58`，SHA-256 由 `build.sh` 核对） |
| `kernel/llmgate.config` | 叠在官方配置之后的片段 |
| `rootfs/packages.txt` | 包清单 |
| `rootfs/customize.sh` | mmdebstrap 装完包后在 chroot 里做的定制 |
| `rootfs/overlay/` | 覆盖进 rootfs 的文件（权限在 `customize.sh` 的清单里逐个写明） |
| `scripts/install-deps.sh` | 构建依赖（`make deps`） |
| `scripts/check-overlay.sh` | 不需要 root 的配方自查（`make check`） |
| `scripts/manifest-entry.py` | 由 `image.json` 生成官网签名清单条目草稿（`make manifest-entry`） |
| `scripts/publish-release.sh` | 建 GitHub Release 并上传 `release/`（`make publish`） |

## 内核

- 版本钉在 `build.sh` 的 `KERNEL_VERSION` / `KERNEL_SHA256`：源码包取自 `cdn.kernel.org`，摘要来自 kernel.org 的
  `sha256sums.asc`（Kernel.org checksum autosigner 签名，指纹 `B8868C80BA62A1FFFAF5FDA9632D3A06589DA6B1`）。
- 配置 = 官方 `microvm-kernel-ci-x86_64-6.18.config` + `llmgate.config`，经 `make olddefconfig` 解依赖。片段补上：
  - SendCtrlAltDel 需要的 i8042 与 AT 键盘（取自官方 `ci.config`），`/proc/config.gz`；
  - `BLK_DEV_WRITE_MOUNTED`（上游缺省开、官方配置关）：Ubuntu 24.04 的 e2fsprogs 1.47.0 在线扩容时也以读写方式打开
    已挂载的块设备，关着会报 EBUSY，每次启动的 `resize2fs` 就失效；
  - k3s / kube-proxy：`NETFILTER_XT_MATCH_{COMMENT,STATISTIC,MARK,MULTIPORT}`、`IP_SET` 与 ipvs 模式及内置网络策略控制器
    用到的集合类型、`NETFILTER_XT_SET`、`IP_VS`（rr / wrr / sh 调度器、TCP / UDP、连接跟踪）与 `-m ipvs`、`physdev`、
    `limit`、`NFLOG`；
  - 时间同步：`PTP_1588_CLOCK_KVM`。
- 片段里每一行都必须原样出现在最终 `.config`（依赖没满足会被 `olddefconfig` 静默丢掉），否则构建失败；产物里的
  `kernel.config` 是实际编译用的完整配置，guest 里也能从 `/proc/config.gz` 读到。
- 可复现：`KBUILD_BUILD_TIMESTAMP` 取版本号里的时刻，构建用户 / 主机名固定，`uname -r` 就是 `KERNEL_VERSION`。

## rootfs

- `mmdebstrap --variant=minbase` 加 `packages.txt` 里的包（不装 Recommends）；软件源是钉在 `build.sh` 的
  `UBUNTU_SNAPSHOT_PIN`（`snapshot.ubuntu.com` 的时间点），同一快照重建得到同一套包版本。man / info / 文档与翻译按 dpkg
  路径规则不装（保留 `/usr/share/doc/*/copyright`），这条规则留在镜像里，VM 里之后装的包同样裁剪。
- 预装：systemd、openssh-server、sudo、git、tmux、curl、ca-certificates、build-essential、python3、chrony、e2fsprogs、
  ffmpeg、fontconfig + fonts-noto-cjk、imagemagick、docker.io，以及常用的压缩与文本工具；完整版本清单见产物
  `rootfs.packages.txt`。
- 用户 `dev`（uid/gid 1000）：口令字段为 `*`（不能口令登录）、`/etc/sudoers.d/90-llmgate-vm` 免密 sudo、在 `docker` 组。
- sshd（`/etc/ssh/sshd_config.d/10-llmgate-vm.conf`）：`HostKey /home/.llmgate-vm/ssh_host_ed25519_key` 是唯一主机密钥；
  只认公钥，禁口令与 root 登录；`AllowStreamLocalForwarding yes`、`AllowTcpForwarding yes`；`MaxSessions 64`、
  `MaxStartups 64:30:256`。系统盘上不留主机密钥，启动时也不生成；用常驻的 `ssh.service`（Ubuntu 缺省的 `ssh.socket`
  关掉，免得数据盘就绪前 22 端口就能连上）。
- `/etc/ssh/ssh_known_hosts` 预置 github.com、gitlab.com 的主机公钥：来源是 `api.github.com/meta` 的 `ssh_keys` 与
  docs.gitlab.com 的 known_hosts 条目；`build.sh` 按钉住的 SHA256 指纹逐条核对，联网时再与两个官方来源比对，对不上即
  停止构建（官方轮换密钥时更新文件与指纹）。`VMIMAGE_OFFLINE=1` 只做本地核对。
- 网络由内核按命令行 `ip=` 配好：networkd、resolved、timesyncd 都屏蔽。chrony 的时钟源由启动时的 init 按实际设备
  生成（`/etc/chrony/chrony.conf` 的 `confdir /run/llmgate-vm/chrony`）：有 KVM PTP 时钟就
  `refclock PHC /dev/ptpN poll 3 dpoll -2 offset 0` 跟宿主走、不连网络；KVM PTP 要宿主支持 `KVM_HC_CLOCK_PAIRING`
  （宿主时钟源是 TSC），嵌套虚拟化的节点上没有这个设备，此时退回 `pool ntp.ubuntu.com`——chronyd 打不开 refclock 设备会
  直接退出，所以不能写死。
- Docker 装好但缺省不启用，数据目录 `/home/.docker-data`（数据盘），`ip6tables: false`（VM 只有 IPv4，内核也没有
  nftables 的 IPv6 表）。journal 落盘、封顶 128 MiB。VM 里 apt 的软件源是 Ubuntu 官方归档。
- 用数据盘的服务排在数据盘之后：`docker.service`、`containerd.service` 与设备纳管后才装到系统盘的 `llmgate-devd.service`
  各带一个 drop-in（`/usr/lib/systemd/system/<单元>.d/llmgate-vm.conf`）——`RequiresMountsFor=/home`、
  `After=llmgate-vm-init.service`。数据盘在 fstab 里是 `nofail`，没挂上时 `home.mount` 失败、它们随之不启动，不会把数据写进
  系统盘上空的 `/home`；drop-in 目录随镜像提供，单元文件后装也照样生效。
- `/etc/machine-id` 为空，每台 VM 首次启动各自生成；`/etc/hostname` 与 `/etc/resolv.conf` 启动时按 VM 写入。

## guest 契约（实现）

**内核命令行**（vmd 下发，Firecracker 自己追加 `root=/dev/vda rw`）：

```
reboot=k panic=1 8250.nr_uarts=0 quiet net.ifnames=0 ip=<IP>::<网关>:<掩码>:<主机名>:eth0:off:<DNS1>:<DNS2>
```

排障时去掉 `8250.nr_uarts=0`、加 `console=ttyS0` 即可在串口看到内核与 systemd 输出。启动到 SSH 可登录约 4–6 秒，
其中内核约 3 秒；Firecracker 文档建议的 `i8042.noaux i8042.nomux i8042.nopnp i8042.dumbkbd` 可省下 i8042 探测的约
0.3 秒，加不加都不影响 SendCtrlAltDel。

**两块盘**：`/dev/vda` 系统盘（根，ext4）；`/dev/vdb` 数据盘，`/etc/fstab` 挂到 `/home`（`nofail`）。

**数据盘种子**（vmd 用 `mke2fs -t ext4 -d <种子>` 生成）：

| 路径（相对种子根 = VM 的 `/home`） | 属主与权限 | 内容 |
|---|---|---|
| `.`（种子根本身） | root | VM 里的 `/home`，在 VM 里总是 root、0755：有的 e2fsprogs 版本会把种子根的权限带进文件系统根，init 每次启动都校正，不依赖种子根的权限 |
| `.llmgate-vm/` | root、0700 | 身份目录 |
| `.llmgate-vm/ssh_host_ed25519_key` | root、0600 | 设备生成的 OpenSSH 私钥 |
| `.llmgate-vm/hostname` | root | 主机名一行（内核命令行没给主机名时的后备） |
| `dev/` | 1000:1000，组与其他人不可写 | dev 的家目录 |
| `dev/.ssh/`、`dev/.ssh/authorized_keys` | 1000:1000、0700 / 0600 | 设备证书公钥那一行 |

**启动顺序**：

1. `llmgate-vm-init.service`（每次启动，排在 `ssh.service` 之前，sshd `Requires` 它）——`/usr/lib/llmgate-vm/init`：
   - `/home` 必须是 `/dev/vdb`，否则失败（写内核日志与 journal），sshd 不启动；
   - 在线 `resize2fs` 数据盘与系统盘：系统盘文件由 vmd 拷贝时撑到 16 GiB，数据盘文件由节点停机时扩大，启动时自动长满；
   - `.llmgate-vm/` 与私钥只校正属主与权限，不改内容；私钥缺失同样失败；
   - 主机名取 `ip=` 第 5 段，没有就读 `.llmgate-vm/hostname`，写 `/etc/hostname` 与 `/etc/hosts` 的 `127.0.1.1` 行；
   - DNS 取 `ip=` 第 8、9 段写 `/etc/resolv.conf`（每次启动覆盖）；
   - `/home` 校正为 root 0755；`/home/dev` 属主 1000:1000、去掉组与其他人的写权限，`.ssh` 与 `authorized_keys` 校正为 0700 / 0600；缺的
     `.bashrc` / `.profile` / `.bash_logout` 从 `/etc/skel` 补上（不递归改属主，不覆盖已有文件）；
   - 按 `/sys/class/ptp/*/clock_name` 找 KVM PTP 时钟，写 chrony 的时钟源（见上文 rootfs）。
2. `ssh.service`。22 端口能连上即说明数据盘、身份与主机名都已就绪。
3. `llmgate-vm-setup.service`（`Type=exec`，排在 sshd 之后）——`/usr/lib/llmgate-vm/setup`：若
   `~dev/workspace/.llmgate/setup.sh` 存在且系统盘上没有标记 `/var/lib/llmgate-vm/setup.done`（单元的
   `ConditionPathExists`），以 dev 的登录 shell 在 `~/workspace` 里跑它（stdin 为 `/dev/null`，`DEBIAN_FRONTEND=noninteractive`
   可穿过 sudo，可执行就直接执行、否则交给 bash），输出的前 4 MiB 写 `/var/log/llmgate-vm/setup.log`（0644）。
   - 启动作业在脚本 exec 之后就完成：脚本在后台跑，不挡登录，也不把 `multi-user.target` 与
     `systemctl is-system-running` 拖到它跑完。跑的时候单元是 `active`，跑完回到 `inactive`（退出码 0）或 `failed`（非零）；
     上限 2 小时（`RuntimeMaxSec`）。
   - 标记是结果的唯一来源：脚本跑完（不论成败）写 `rc=<退出码>`、`started=<UTC 时刻>`、`finished=<UTC 时刻>` 三行
     （root、0644，dev 可读），之后这块系统盘不再跑。镜像里没有标记，所以新 VM 与重建系统盘后的第一次启动都会跑；
     脚本不存在时、脚本被停下时（关机、到上限）不写标记，下次启动再看。
   - VM 刚建好时仓库还没 clone：设备在 clone 之后触发一次（见下）。手工触发是
     `sudo systemctl start llmgate-vm-setup.service`（立即返回），重跑先删标记。

**设备触发**（固件 `firmware/internal/devhost/vmsetup.go` 的 `RunVMSetup`，建立工作空间的 setup 步骤调用）：以 dev 身份在一个 SSH
会话里跑一段固定脚本——没有标记时，仓库里没有 `setup.sh` 即报 `absent`，否则 `sudo systemctl start` 这个单元；然后等单元
不再是 `active`（等待有上限 `vmSetupWait`，整条命令在 `agenthost.MaxRunTimeout` 之内），按标记报结果。标记在触发之前就有
时不再触发，直接报它记下的结果。脚本输出的第一行是 `setup=<结果>`，其后是日志尾段：

| 结果 | 条件 | 其后的输出 |
|---|---|---|
| `absent` | 没有标记，仓库里也没有 `setup.sh` | — |
| `ok` | 标记里 `rc=0` | — |
| `failed` | 标记里 `rc` 非零；或单元没把脚本跑起来（单元停下了、没有标记、脚本还在） | `setup.log` 最后 20 行；没跑起来时是 systemctl 的报错与单元 journal 的最后 20 行 |
| `running` | 等到上限单元还是 `active`（单元照常跑完，结果之后看标记与日志） | `setup.log` 目前的最后 20 行 |

**三种退出**：

| 情形 | guest 里发生的事 | Firecracker |
|---|---|---|
| guest 重启（`reboot`） | 内核 `reboot=k` 走键盘控制器复位 | 退出（退出码 0），包装按「需要重启」处理 |
| guest 关机（`poweroff` / `halt`） | 关机钩子 `/usr/lib/systemd/system-shutdown/llmgate` 在最后一步连 vsock CID 2 端口 10240，写一行 `poweroff`，等节点关连接（最多 3 秒） | 不会自己退出；包装在 `<uds_path>_10240` 上收到这一行后结束它 |
| 管理员停止 | vmd 调 `SendCtrlAltDel` → systemd 的 ctrl-alt-del 走重启流程 | 同 guest 重启，退出 |

关机钩子用镜像里的 `python3 -I -S`（`socket.AF_VSOCK`），不另带二进制；此时根文件系统已只读，不影响它运行。

**Firecracker 侧**：API socket 与 vsock 的 `uds_path` 由 Firecracker 自己创建，上次运行留下的文件会让它启动失败，每次
启动前先删掉（包装监听的 `<uds_path>_10240` 由包装自己管理）。

**版本标记**：`/etc/llmgate-vm-release` 一行 `lgvm1{<版本>|}lgvm1`，形状检查对 `rootfs.ext4` 按字节扫描即可认出。

**系统盘**：`rootfs.ext4` 在装好的内容之外只留约 2 GiB；节点的 vmd 拷贝系统盘时一律把文件撑到 16 GiB（稀疏，不占
实际空间；`vmd.SystemDiskMinBytes`），guest 每次启动在线 `resize2fs` 长满，`setup.sh` 用 apt 装系统依赖才放得下。
系统盘上的东西随重建丢失：`apt` 装的包、`/usr/local`、`/etc` 下的改动（包括纳管时装在系统盘上的 devd 二进制与
unit）；`$HOME`、Docker 数据与身份都在数据盘上。

## 构建

构建机：Linux x86-64、root（mmdebstrap 的 root 模式与 `mke2fs -d` 保留属主）、约 10 GiB 空闲空间，能访问
`cdn.kernel.org`、`snapshot.ubuntu.com`（或 `UBUNTU_MIRROR` 指定的 HTTPS 镜像站），核对主机公钥时访问 `api.github.com` 与
`docs.gitlab.com`。

```sh
sudo make deps                                  # gcc make flex bison bc libelf-dev libssl-dev mmdebstrap e2fsprogs …
sudo make image VERSION=<版本>                  # VERSION 缺省由 Makefile 按本仓库提交生成（make print-version）
sudo VERSION=<YYMMDDHHMM-xxxx> ./build.sh       # 同上，不经 make
```

| 环境变量 | 作用 |
|---|---|
| `VERSION` | 必填（`make` 目标自动给），`YYMMDDHHMM-xxxx`，脏树带 `-d` |
| `OUT` | 产物目录，缺省 `bin/<VERSION>/` |
| `JOBS` | 内核编译并发，缺省 `nproc` |
| `UBUNTU_SNAPSHOT` | 换一个快照时间点（形如 `20260929T000000Z`） |
| `UBUNTU_MIRROR` | 改用某个 HTTPS 镜像站的当前内容（不走快照，只为本地加快；`SOURCES.txt` 与 `image.json` 如实记录） |
| `ROOTFS_FREE_MIB` | rootfs 在内容之外留的空间，缺省 2048 |
| `VMIMAGE_OFFLINE=1` | 不联网复核预置主机公钥 |

产物（`bin/<VERSION>/`，gitignored；先写 `<VERSION>.tmp`，全部成功才换上）：

| 文件 | 内容 |
|---|---|
| `vmlinux`、`vmlinux.gz` | 内核及其 gzip（`-9 -n`） |
| `rootfs.ext4`、`rootfs.ext4.gz` | rootfs 及其 gzip |
| `image.json` | 版本、平台 `linux-amd64`、架构 `x86_64`、格式 gzip、两部分的 `gz_size` / `gz_sha256` / `size` / `sha256`（与设备侧 `vmd.ImagePart` 同名）、许可证与源码来源 |
| `SHA256SUMS` | 目录里其余文件的 SHA-256 |
| `kernel.config` | 实际编译用的完整内核配置 |
| `rootfs.packages.txt` | rootfs 里每个包的名称、版本、源码包与源码版本 |
| `SOURCES.txt` | 许可证与源码来源说明 |
| `release/` | 发布时原样上传的全部 asset：两部分按 Release 文件名（`vmlinux-<版本>-x86_64.gz`、`rootfs-<版本>-x86_64.ext4.gz`，与设备侧 `firmware/internal/vmimage` 的 `KernelURL` / `RootfsURL` 一致）的硬链接、上面四个说明文件、内核源码包与它们的 `SHA256SUMS` |

下载缓存（内核源码包、`.deb`）与构建树在 `bin/.cache`、`bin/.work`：重复执行时内核增量编译，rootfs 每次从
头建（`.deb` 走缓存，缓存只留最近一次用到的包）。同一台机器同时只能跑一个构建。参考量级（16 核、下载约 1 MB/s）：
冷构建约 17 分钟（内核源码下载与编译各约 2.5 分钟、rootfs 约 8 分钟、gzip 约 3.5 分钟），缓存齐全时约 6 分钟；rootfs 内容
约 1.3 GiB、`rootfs.ext4` 3.5 GiB、压缩后约 490 MiB，`vmlinux` 约 29 MiB、压缩后约 10 MiB（确切值以产物里的
`image.json` 为准）。

## 开机测试

```sh
sudo make boot-test VERSION=<版本>     # 即 ./boot-test.sh bin/<版本>；SERIAL=1 打开串口日志，KEEP=1 保留临时目录
```

脚本下载 Firecracker v1.17.0 官方整包（核对 SHA-256，缓存在 `/var/tmp/llmgate-vmimage-test`），建临时 tap（缺省
`lgvmtest0`，`172.30.254.0/30`，与本机路由冲突时拒绝）与 vsock 监听，按 vmd 的方式建系统盘（稀疏拷贝并撑到 16 GiB）与数据
盘（`mke2fs -d` 种子；种子根故意给 0700，验 init 把 `/home` 校正为 root 0755；带一个计次数的 `setup.sh`，它先等
`~/setup-go` 出现，好确认它在后台跑的时候开机已经完成），以 `--enable-pci`、生产的内核命令行启动三次：

1. 新 VM：钉住的主机公钥、dev 登录与免密 sudo、`/home` 是数据盘且为 root 0755、主机名与 DNS、`sshd -T` 的各项、没有生成主机密钥、
   direct-tcpip / streamlocal / 远程 TCP 转发、chronyd 在运行（有 KVM PTP 时选中 PHC，没有时退回 NTP 池）、
   `/proc/config.gz` 含片段全部项、`setup.sh` 还在后台跑（单元 `active`）时 systemd 已到 `running` 且无失败单元、
   docker / containerd / 临时装上的 `llmgate-devd.service` 都要求 `/home` 挂好并排在 init 之后、
   Docker 缺省不启用且手工启用后数据目录在数据盘、放行后 `setup.sh` 跑一次且标记为 `rc=0`、根文件系统在线扩到系统盘大小；
   然后 guest `reboot`，Firecracker 应退出且不发关机通知。
2. 数据盘扩大 4 GiB、命令行不带主机名：数据盘在线扩容、主机名退回 `.llmgate-vm/hostname`、`setup.sh` 不重跑；然后
   `SendCtrlAltDel`，Firecracker 应退出。
3. 重建系统盘：`setup.sh` 再跑一次、主机公钥不变；然后 guest `poweroff`，vsock 上应收到 `poweroff`。

只结束自己起的进程（按 PID），结束时删掉 tap 与临时目录，不改本机 sysctl、路由与防火墙。I/O 性能与长时间稳定性要在
真实 KVM 节点上测，不在这个脚本里。
