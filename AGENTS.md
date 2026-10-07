# LLM Gate VM Image — Repository Instructions

LLM Gate Firecracker 节点所用 guest 镜像（Linux 内核 + Ubuntu 24.04 rootfs）的配方与发布仓库，维护方 llm.net 团队。本仓库是配方的唯一维护源：只凭本仓库就能改配方、构建、测试并发布 GitHub Release；设备装哪个版本由 llm.net 签名清单决定，清单在 LLM Gate 主仓签名部署。

| 入口 | 内容 |
|---|---|
| [README.md](README.md) / [README.zh-CN.md](README.zh-CN.md) | 用途、镜像内容、Release asset、构建快速入口（英文默认，两份内容一致） |
| [docs/design.md](docs/design.md) | 内核与 rootfs 配方机制、guest 契约、构建产物、开机测试 |
| [docs/maintenance.md](docs/maintenance.md) | 版本规则、发布十步、交给主仓的清单条目、各类升级、排障 |
| `Makefile` | `print-version` `deps` `image` `boot-test` `manifest-entry` `publish` `check` |

## 规则

- **禁止自动提交与发布**：改完文件、构建或测试后保留未提交改动；`git commit`、`git push`、`git tag`、`make publish` 都只在用户明确要求时执行。完成任务不构成提交或发布授权。
- 禁止破坏性 Git 操作（`reset --hard`、强推、改写已推送历史）与切分支；已推送的 tag 与已发布的 asset 不改、不删、不覆盖，同一版本不重复发布，有问题就发新版本。
- 版本只用 `make print-version` 在干净工作树上取一次，之后每一步显式传 `VERSION=`；tag 打在取版本的那个提交上。`-d` 版本只用于本地测试。
- 构建、开机测试要 root；开机测试要 `/dev/kvm`。在真实 Firecracker 节点或任何远程主机上验证须先征得用户同意。
- 令牌只从环境变量 `GH_TOKEN` / `GITHUB_TOKEN` 读，不写进仓库文件、命令行参数、日志、提交信息或对话输出。禁止关闭 TLS 校验，禁止为绕过失败而修改钉住的 SHA-256 或指纹。
- 生成物只落 gitignored 的 `bin/`，不入库。
- `kernel/microvm-kernel-ci-x86_64-*.config` 是 Firecracker 官方文件，原样入库不手改；内核改动只写 `kernel/llmgate.config`。
- `rootfs/overlay/` 的每个文件必须在 `rootfs/customize.sh` 的 `overlay_files` 里写明权限；改完跑 `make check`。
- 只装 Ubuntu noble main / universe 的包，不加第三方源；发布版本必须从 `build.sh` 钉住的 `snapshot.ubuntu.com` 时间点构建，不用 `UBUNTU_MIRROR`。
- guest 契约（用户、身份目录、磁盘、内核命令行、vsock、版本标记、`setup.sh`）与 LLM Gate 固件 `firmware/internal/vmd/api.go` 共同遵守：改它须先由主仓改固件，见 [docs/maintenance.md](docs/maintenance.md)「改 guest 契约」。
- 改配方时同步 README 两份的「镜像内容」与 `docs/`；`.md` 只写现状，不写日期、变更经过或一次性事故。
- 不接受外部贡献或 PR（`.github/workflows/close-pull-requests.yml` 自动关闭，不检出、不执行 PR 代码）；不建 `CLAUDE.md`，指令只写本文件。

## 与 LLM Gate 主仓的边界

| 本仓库 | 主仓（llm-net/llm-gate 固件源码 + 官网） |
|---|---|
| 配方、构建、开机测试、GitHub Release | 设备侧清单策略 `firmware/internal/vmimage`、节点守护进程 `firmware/internal/vmd` |
| `make manifest-entry` 生成清单条目草稿 | 把条目写进 `/updates/components/vm-image/stable.json`、递增 `revision`、签名、部署官网 |

发布后把 `make manifest-entry VERSION=<版本>` 的输出交给用户或主仓，说明尚未签名部署、设备暂不可见。
