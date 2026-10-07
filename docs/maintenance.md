# 构建、发布与升级

本仓库是 VM 镜像配方的唯一维护源：改配方、构建、测试、发 GitHub Release 都在这里完成。设备真正装哪个版本由 llm.net 上的签名清单决定，清单的签名与部署在 LLM Gate 主仓（见下文「交给主仓：签名清单」）。配方与 guest 契约的机制见 [design.md](design.md)。

## 版本

- 版本 `YYMMDDHHMM-xxxx`：构建时刻（构建机本地时区，精确到分钟）+ 本仓库 HEAD 七位短哈希的末四位；工作树不干净时带 `-d`。`make print-version` 打印它。
- 只有干净工作树上取得的版本能发布：tag `<版本>` 打在取版本的那个提交上，`publish-release.sh` 核对 tag 提交哈希末四位等于版本的 `xxxx`。`-d` 版本只用于本地测试。
- 设备只比较十位时间戳：新版本的时间戳必须大于清单里已有的所有版本，同一分钟的两个版本互不构成升级。
- 同一版本不重复发布；已发布的 tag 与 asset 不改、不删、不覆盖。发现问题就发新版本，并在清单里阻断旧版本。
- 构建以后再改任何追踪文件（包括文档）都会让 HEAD 变化：先把配方与文档改完并提交，再取版本、构建；构建后发现要改，就再提交一次、重新取版本重新构建。

## 构建机

Linux x86-64、root、约 10 GiB 空闲空间，HTTPS 能到 `cdn.kernel.org`、`snapshot.ubuntu.com`、`api.github.com`、`docs.gitlab.com`；开机测试另需可读写的 `/dev/kvm`。参考耗时：冷构建约 17 分钟，下载缓存齐全时约 6 分钟（16 核）。

```sh
sudo make deps          # 按包名补装缺的构建依赖（Ubuntu 24.04；可重复执行）
make check              # 不需要 root：脚本语法、overlay 权限清单与 rootfs/overlay/ 一致、packages.txt 无重复
```

`bin/` 是唯一的输出目录（gitignored）：`bin/<版本>/` 是产物，`bin/.cache` 是内核源码包与 `.deb` 缓存，`bin/.work` 是内核构建树，`bin/.lock` 保证同一台机器同时只跑一个构建。构建中断留下的 `bin/.work/rootfs` 挂载要先手工卸载，脚本检测到会停下、不会 `rm -rf` 进挂载点。

## 发布

发布是对外动作，须用户明确要求；每一步失败都停下报告，不跳过。

1. **改好并提交配方**：`make check` 通过；README 两份「镜像内容」里装了什么、配了什么与本次改动一致（具体版本号第 10 步再改）；提交到 `main`。
2. **取版本**：工作树干净时 `V=$(make -s print-version)`，确认不带 `-d`。之后每一步都显式传 `VERSION=$V`。
3. **构建**：`sudo make image VERSION=$V`。产物目录 `bin/$V/` 里 `SHA256SUMS`、`image.json`、`release/` 齐全才算成功。
4. **核对内容变化**：把 `bin/$V/rootfs.packages.txt`、`bin/$V/kernel.config` 与上一个 Release 的同名 asset 比较（`curl -fsSL https://github.com/llm-net/llm-gate-vm-image/releases/download/<上一版本>/rootfs.packages.txt`），差异与本次改动的意图一致；`image.json` 里两部分的大小没有异常跳变。
5. **开机测试**：`sudo make boot-test VERSION=$V`，全部 `ok`、没有 `FAIL`。它在本机起 microVM 验证 guest 契约与三种退出路径（[design.md](design.md)「开机测试」）。要在真实 Firecracker 节点上再验一台，须先征得用户同意使用哪台节点。
6. **打 tag 并推送**：`git tag $V && git push origin main $V`。tag 必须指向第 2 步取版本时的 HEAD。
7. **建 Release 并上传**：令牌放进环境变量 `GH_TOKEN`（本仓库 contents 写权限），`make publish VERSION=$V`。脚本核对产物、tag 与远端，新建 Release（说明由 `image.json` 生成，中英文），逐个上传 `release/` 的 8 个文件，最后复核 Release 上的 asset 与本地一致。上传中断时重跑同一命令，只补传缺的；同名 asset 不一致会停下，不覆盖。
8. **生成清单条目**：`make manifest-entry VERSION=$V`，或 `python3 -I scripts/manifest-entry.py bin/$V/image.json --check`（`--check` 对 Release 上的两部分与内核源码包发 HEAD，核对存在且长度一致）。
9. **交给主仓**：把第 8 步的条目交给 LLM Gate 主仓签名部署（下一节）。部署之前设备看不到新版本。
10. **更新 README 的版本号**：按 `bin/$V/rootfs.packages.txt` 与 `image.json` 改两份 README「镜像内容」的 Release 版本、包数、内容体积与各软件版本，单独提交（只改文档，不重新构建镜像；tag 仍指向第 2 步的提交）。

令牌只从环境变量读：不写进仓库文件、命令行参数、日志、提交信息或对话输出。`publish-release.sh` 把它写进 0600 临时文件交给 curl，结束即删。

## 交给主仓：签名清单

清单 `https://llm.net/updates/components/vm-image/stable.json` 与签名 `stable.json.sig` 由 LLM Gate 主仓维护（官网目录 `website/public/updates/components/vm-image/`），签名私钥只在主仓所在的机器上，本仓库不放清单副本、也不签名。主仓那一侧要做的事：

1. 把 `manifest-entry.py` 输出的条目追加到 `releases`；已有条目保留（节点上装着的旧版本据此识别），要撤下某个版本就把它的 `blocked` 改为 `true`，或把 `allowInstall` / `allowUpdate` 改为 `false`。
2. `revision` 加一，`updatedAt` 写当前 UTC 时刻（`YYYY-MM-DDTHH:MM:SSZ`）。
3. 按主仓 `website/AGENTS.md`「组件清单签名」用 `firmware/tools/componentsign` 重签，跑固件 `internal/vmimage` 的测试（含 `website_manifest_test.go`），部署官网。

条目字段与设备侧校验（固件 `firmware/internal/vmimage` 的 `Release.validate`）一一对应：

| 字段 | 取值 |
|---|---|
| `version` / `platform` / `packaging` | 版本、`linux-amd64`、`gzip` |
| `kernel.artifactUrl` | 只能是 `https://github.com/llm-net/llm-gate-vm-image/releases/download/<版本>/vmlinux-<版本>-x86_64.gz` |
| `rootfs.artifactUrl` | 只能是 `…/releases/download/<版本>/rootfs-<版本>-x86_64.ext4.gz` |
| `artifactSha256` / `sizeBytes` | `image.json` 的 `gz_sha256` / `gz_size` |
| `unpackedSha256` / `unpackedSizeBytes` | `image.json` 的 `sha256` / `size` |
| `kernel.license` | 恒为 `GPL-2.0` |
| `kernel.sourceUrl` | 同一 Release 的 `linux-<内核版本>.tar.xz` |
| `rootfs.sourceUrl` | `https://github.com/llm-net/llm-gate-vm-image/tree/<版本>` |
| `minComponentManager` | 设备侧 VM 镜像管理器协议版本，当前为 `1`（见下文「改 guest 契约」） |

设备侧上限：内核 gzip ≤ 128 MiB、解压 ≤ 512 MiB；rootfs gzip ≤ 4 GiB、解压 ≤ 32 GiB。

## 升级

每类升级都走上面的「发布」全流程；下面只写各自要改什么、怎么核对。

### Ubuntu 安全更新（最常见）

1. 选一个新的快照时间点（UTC，形如 `20261101T000000Z`），确认它存在：`curl -fsI https://snapshot.ubuntu.com/ubuntu/<时间点>/dists/noble-security/InRelease`。
2. 改 `build.sh` 的 `UBUNTU_SNAPSHOT_PIN`。可以先不改文件、用 `sudo UBUNTU_SNAPSHOT=<时间点> make image VERSION=<-d 版本>` 试建。
3. 发布第 4 步对比包清单：只应有版本号变化；多出或少了包要查明原因（通常是依赖变化）。

不要用 `UBUNTU_MIRROR` 构建要发布的版本：它不走快照、不可复现，`manifest-entry.py` 会拒绝这种 `image.json`。

### 内核补丁版本

1. 只在 6.18 系列内升补丁版本（Firecracker 官方 guest 配置按内核系列提供，换系列见下一小节）。
2. 从 `https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc` 取新版本的 SHA-256，并用 `gpg --verify` 核对签名（Kernel.org checksum autosigner，指纹 `B8868C80BA62A1FFFAF5FDA9632D3A06589DA6B1`，公钥从 kernel.org 文档或 WKD 取得）。
3. 改 `build.sh` 的 `KERNEL_VERSION` 与 `KERNEL_SHA256`。构建会逐行核对 `kernel/llmgate.config` 在最终配置里全部生效，依赖变化导致某项被丢掉时构建失败——按报错调整片段，不要删核对。
4. 对比 `kernel.config` 与上一版的差异。

### Firecracker guest 配置或内核系列

1. 从 Firecracker 新标签的 `resources/guest_configs/` 原样取回对应内核系列的 `microvm-kernel-ci-x86_64-<系列>.config` 放进 `kernel/`（不手改；我们的改动只写在 `llmgate.config` 里），删掉旧文件。
2. 改 `build.sh` 的 `FC_TAG`、`FC_COMMIT`、`FC_BASE_CONFIG`、`FC_BASE_CONFIG_SHA256`；换系列时连同 `KERNEL_VERSION` / `KERNEL_SHA256` 一起改。
3. `boot-test.sh` 的 `FC_VERSION` / `FC_SHA256` 是测试用的 Firecracker 整包，应与设备给节点装的版本一致（官网 `/updates/components/firecracker/stable.json`）；节点的 Firecracker 升级后同步改这里。
4. 同步 `docs/design.md`「目录」与「内核」里的版本与文件名。

### 包清单

1. 改 `rootfs/packages.txt`，一行一个包，按现有分组写注释说明用途；只装 Ubuntu noble main / universe 里的包，不另加第三方源。
2. 镜像体积影响每台 VM 的系统盘（节点拷贝后撑到 16 GiB）与下载时间；大件（IDE、语言运行时、开发工具 CLI）不进镜像，交给 LLM Gate 建立工作空间时安装或仓库的 `.llmgate/setup.sh`。
3. 对比包清单，确认没有意外拉进的大依赖；`make check` 会拦下重复项。

### overlay 与定制脚本

- `rootfs/overlay/` 下每个文件都必须在 `rootfs/customize.sh` 的 `overlay_files` 里写明权限，多一个少一个都会让 `make check` 与构建失败。
- 服务若要用数据盘（`/home`），照 `docker.service.d/llmgate-vm.conf` 加 drop-in：`RequiresMountsFor=/home` 与 `After=llmgate-vm-init.service`。
- 系统盘上不能出现 SSH 主机密钥，也不能有启动时生成主机密钥的单元（`customize.sh` 会检查）。

### 预置主机公钥轮换

github.com 或 gitlab.com 轮换 SSH 主机密钥后构建会停在「核对预置主机公钥」。按官方来源（`https://api.github.com/meta` 的 `ssh_keys`、`https://docs.gitlab.com/user/gitlab_com/`）更新 `rootfs/overlay/etc/ssh/ssh_known_hosts` 与 `build.sh` 的 `KNOWN_HOSTS_FINGERPRINTS`，两处必须一致。

### 改 guest 契约

用户 `dev` / uid 1000、身份目录与主机密钥文件名、两块盘的设备名与挂载点、内核命令行格式、vsock 端口与关机消息、版本标记格式、`.llmgate/setup.sh` 的标记与日志位置、单元名——这些是镜像与 LLM Gate 固件（`firmware/internal/vmd/api.go`、`firmware/internal/devhost/vmsetup.go`）共同遵守的约定，只改本仓库会让设备建不起或管不住 VM。

- 先在主仓改固件并发布，再发依赖新约定的镜像；旧固件不认的改动要提高清单条目的 `minComponentManager`（与固件的 `vmimage.ComponentManagerVersion` 一起改），旧固件就会跳过这个版本。
- 同步 `docs/design.md`「guest 契约」与 `boot-test.sh` 的核对项。

## 改配方时同步的文档

- `README.md` 与 `README.zh-CN.md`「镜像内容」：内核版本与配置来源、Ubuntu 快照时间点、包数与内容体积、各类别的软件及主要版本（取自 `bin/<版本>/rootfs.packages.txt`）、「没有预装」、预置配置。两份 README 内容一致，英文是默认入口。
- `docs/design.md`：配方机制、guest 契约、构建产物与开机测试。
- 本文件：流程与升级方法。
- `.md` 只写现状，不写日期、变更经过或一次性事故；版本号、快照时间点等仍生效的事实照写。

## 排障

| 现象 | 处理 |
|---|---|
| `另一个 vmimage 构建正在进行` | 同机已有构建在跑；确认没有之后才删 `bin/.lock` |
| `下还有挂载（上次构建中断？）` | `findmnt -R bin/.work/rootfs` 查出挂载，逐个 `umount` 后重跑 |
| `摘要不符` | 下载内容与钉住的 SHA-256 不一致：不要改摘要绕过，先核对上游来源 |
| `最终配置里没有 CONFIG_…` | 片段某项的依赖没满足，被 `olddefconfig` 丢掉；补上依赖项或调整片段 |
| `ssh_known_hosts 与钉住的指纹不一致` / 与官方来源不一致 | 见「预置主机公钥轮换」；离线构建可设 `VMIMAGE_OFFLINE=1` 只做本地核对 |
| 开机测试 `FAIL` | `SERIAL=1 KEEP=1 sudo make boot-test VERSION=…` 看串口日志与保留的临时目录 |
