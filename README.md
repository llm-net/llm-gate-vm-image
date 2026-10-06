# LLM Gate VM Image

**English** | [简体中文](README.zh-CN.md)

Guest images for the Firecracker nodes of [LLM Gate](https://github.com/llm-net/llm-gate). Every microVM that LLM Gate creates for a VM workspace boots from one of these images: a Linux kernel plus an Ubuntu 24.04 root filesystem, x86-64 only.

You normally don't download anything here by hand. An LLM Gate device verifies the signed manifest at `https://llm.net/updates/components/vm-image/stable.json`, then installs the exact assets it lists onto a Firecracker node, checking length and SHA-256 before and after decompression. Devices never follow the "latest" release.

## Releases

Each release tag is the image version (`YYMMDDHHMM-xxxx`, the same format as the firmware, no `v` prefix) and points at the recipe that built it. Assets:

| Asset | Content |
|---|---|
| `vmlinux-<version>-x86_64.gz` | Linux kernel, uncompressed ELF, gzip-compressed |
| `rootfs-<version>-x86_64.ext4.gz` | Ubuntu 24.04 root filesystem (ext4 image), gzip-compressed |
| `image.json` | Version, platform, and the length and SHA-256 of both parts before and after decompression |
| `kernel.config` | Complete kernel configuration used for the build |
| `rootfs.packages.txt` | Every package in the root filesystem with its version, source package and source version |
| `SOURCES.txt` | Licenses and source locations |
| `linux-<kernel version>.tar.xz` | Unmodified upstream kernel source |
| `SHA256SUMS` | SHA-256 of the other assets |

Verify a download with `sha256sum -c SHA256SUMS`.

## Build

The recipe is in [`firmware/vmimage/`](firmware/vmimage/), a snapshot of the same directory in [llm-net/llm-gate](https://github.com/llm-net/llm-gate); its README (Chinese) documents the kernel configuration, the root filesystem and the contract between the guest and the node. Paths it links outside `firmware/vmimage/` refer to the llm-net/llm-gate repository.

Building needs Linux x86-64, root, about 10 GiB of free space and HTTPS access to `cdn.kernel.org` and `snapshot.ubuntu.com`. On Ubuntu 24.04:

```sh
sudo apt-get install --no-install-recommends gcc make flex bison bc libelf-dev libssl-dev perl xz-utils \
  gzip python3 ca-certificates curl mmdebstrap ubuntu-keyring e2fsprogs openssh-client
sudo VERSION=<version> firmware/vmimage/build.sh                 # output: firmware/bin/vmimage/<version>/
sudo firmware/vmimage/boot-test.sh firmware/bin/vmimage/<version> # boot smoke test, needs /dev/kvm
```

The kernel version and SHA-256, the Firecracker guest configuration and the Ubuntu snapshot timestamp are pinned in `build.sh`, so rebuilding a tag uses the same kernel configuration and the same package versions.

## License

- Recipe (the files in this repository): [MIT](LICENSE).
- Linux kernel: GPL-2.0-only. Each release ships the unmodified upstream source and the exact configuration used.
- Root filesystem: each Ubuntu package under its own license, with the text in `/usr/share/doc/<package>/copyright` inside the image. Sources are available from the pinned `snapshot.ubuntu.com` timestamp, using the source packages and versions in `rootfs.packages.txt`.

## Feedback

This repository does **not accept external contributions or pull requests**; pull requests are closed automatically. For feedback use [LLM Gate Issues](https://github.com/llm-net/llm-gate/issues), and report security vulnerabilities privately as described in [SECURITY.md](https://github.com/llm-net/llm-gate/blob/main/SECURITY.md).
