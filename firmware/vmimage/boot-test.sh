#!/usr/bin/env bash
# VM 镜像开机冒烟测试：用 Firecracker 官方整包在本机起一台 microVM，按 vmd 的方式建系统盘与数据盘（mke2fs -d 种子）、
# 传内核命令行，逐项核对 guest 契约（firmware/internal/vmd/api.go「guest 与节点之间的约定」）与三种退出路径。
#
#   sudo firmware/vmimage/boot-test.sh firmware/bin/vmimage/<VERSION>
#
# 需要：root、/dev/kvm、iproute2、e2fsprogs、openssh-client、python3、curl。冒烟测试不经 jailer。
#
# 环境变量：
#   FC_DIR        Firecracker 整包的下载与解包目录（缺省 /var/tmp/llmgate-vmimage-test，核对钉住的 SHA-256）
#   TAP           临时 tap 名（缺省 lgvmtest0）；TEST_NET 临时 /30 网段的前三段加末段基数（缺省 172.30.254.0）
#   SERIAL=1      打开串口，guest 控制台写到临时目录的 serial.log（排障用；缺省与生产一样关着）
#   KEEP=1        结束时保留临时目录（盘、密钥、日志）以便排查
#
# 清理：只结束本脚本起的进程（按 PID），删掉临时 tap 与临时目录；不改本机的 sysctl、路由表与防火墙。
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE_DIR=$(realpath "${1:?用法：boot-test.sh <镜像产物目录，如 firmware/bin/vmimage/VERSION>}")

FC_VERSION=1.17.0
FC_ARCH=x86_64
FC_TGZ=firecracker-v$FC_VERSION-$FC_ARCH.tgz
FC_URL=https://github.com/firecracker-microvm/firecracker/releases/download/v$FC_VERSION/$FC_TGZ
FC_SHA256=06094a1108ae9e82aa4c23a775aa92758f53f1175d422270d9d6162cb9ade558
FC_DIR=${FC_DIR:-/var/tmp/llmgate-vmimage-test}

TAP=${TAP:-lgvmtest0}
TEST_NET=${TEST_NET:-172.30.254.0}
NET3=${TEST_NET%.*}
NET4=${TEST_NET##*.}
HOST_IP=$NET3.$((NET4 + 1))
GUEST_IP=$NET3.$((NET4 + 2))
NETMASK=255.255.255.252
DNS1=$HOST_IP
DNS2=223.5.5.5
NAME_CMDLINE=lgvm-test
NAME_SEED=lgvm-seed
GUEST_MAC=06:00:ac:1e:fe:02
VCPUS=2
MEM_MIB=2048
SYSTEM_GIB=16
DATA_GIB=16
BOOT_TIMEOUT=90

pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok    %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$*"; }
check() { # check 名称 期望 实际
	if [ "$2" = "$3" ]; then ok "$1（$3）"; else bad "$1：期望 [$2]，实际 [$3]"; fi
}
die() { echo "boot-test: $*" >&2; exit 1; }
note() { printf '\n--- %s\n' "$*"; }

# ---- 前置 ----
[[ $(id -u) == 0 ]] || die "需要 root（tap、KVM）"
[ -r /dev/kvm ] && [ -w /dev/kvm ] || die "/dev/kvm 不可读写"
for c in ip mke2fs ssh ssh-keygen ssh-keyscan python3 curl truncate; do
	command -v "$c" >/dev/null 2>&1 || die "缺少 $c"
done
for f in vmlinux rootfs.ext4 image.json; do [ -f "$IMAGE_DIR/$f" ] || die "$IMAGE_DIR 里没有 $f"; done
IMAGE_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$IMAGE_DIR/image.json")
LINUX_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kernel"]["linux_version"])' "$IMAGE_DIR/image.json")
if ip link show "$TAP" >/dev/null 2>&1; then die "$TAP 已存在（上次测试没清理？）"; fi
# 临时网段不能与本机已有路由重叠：只允许默认路由命中测试地址。
if ip -4 route show to match "$GUEST_IP" | grep -qv '^default '; then
	die "测试网段 $TEST_NET/30 与本机路由冲突：$(ip -4 route show to match "$GUEST_IP" | grep -v '^default ')"
fi

# ---- Firecracker 官方整包 ----
mkdir -p "$FC_DIR"
if ! echo "$FC_SHA256  $FC_DIR/$FC_TGZ" | sha256sum -c --quiet >/dev/null 2>&1; then
	curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$FC_DIR/$FC_TGZ.part" "$FC_URL"
	echo "$FC_SHA256  $FC_DIR/$FC_TGZ.part" | sha256sum -c --quiet || die "Firecracker 整包摘要不符"
	mv -f "$FC_DIR/$FC_TGZ.part" "$FC_DIR/$FC_TGZ"
fi
FC_BIN=$FC_DIR/release-v$FC_VERSION-$FC_ARCH/firecracker-v$FC_VERSION-$FC_ARCH
if [ ! -x "$FC_BIN" ]; then
	tar -C "$FC_DIR" -xzf "$FC_DIR/$FC_TGZ" "release-v$FC_VERSION-$FC_ARCH/firecracker-v$FC_VERSION-$FC_ARCH"
fi
"$FC_BIN" --version | head -n 1

# ---- 临时目录、清理 ----
RUN=$(mktemp -d "$FC_DIR/run.XXXXXX")
chmod 0700 "$RUN"
pids=()
cleanup() {
	local p
	for p in "${pids[@]}"; do
		kill -KILL "$p" 2>/dev/null || true
		wait "$p" 2>/dev/null || true
	done
	ip link del "$TAP" 2>/dev/null || true
	if [ "${KEEP:-0}" = 1 ]; then echo "保留临时目录 $RUN"; else rm -rf "$RUN"; fi
}
trap cleanup EXIT

# ---- 密钥：主机密钥（设备生成的那把）与测试客户端密钥（充当设备证书公钥，注释 llmgate-agent） ----
ssh-keygen -q -t ed25519 -N '' -C '' -f "$RUN/hostkey"
ssh-keygen -q -t ed25519 -N '' -C 'llmgate-agent' -f "$RUN/client"
echo "$GUEST_IP $(cut -d' ' -f1,2 "$RUN/hostkey.pub")" >"$RUN/known_hosts"
HOSTKEY_FP=$(ssh-keygen -lf "$RUN/hostkey.pub" | awk '{ print $2 }')

# ---- 系统盘：同 vmd——镜像 rootfs 的稀疏拷贝，文件撑到 SYSTEM_GIB（验 guest 启动时在线扩根文件系统） ----
make_system_disk() {
	rm -f "$RUN/system.ext4"
	cp --sparse=always "$IMAGE_DIR/rootfs.ext4" "$RUN/system.ext4"
	if [ "$(stat -c %s "$RUN/system.ext4")" -lt $((SYSTEM_GIB << 30)) ]; then
		truncate -s "${SYSTEM_GIB}G" "$RUN/system.ext4"
	fi
}

# ---- 数据盘：vmd 的做法（第 5.2 节）——稀疏文件 + mke2fs -d 种子，不挂载 ----
make_data_disk() {
	local seed=$RUN/seed
	rm -rf "$seed"
	# 种子根故意给 root 0700：不论种子根是什么权限，VM 里的 /home 都应被 init 校正为 root 0755。
	install -d -o 0 -g 0 -m 0700 "$seed"
	install -d -o 0 -g 0 -m 0700 "$seed/.llmgate-vm"
	install -o 0 -g 0 -m 0600 "$RUN/hostkey" "$seed/.llmgate-vm/ssh_host_ed25519_key"
	echo "$NAME_SEED" >"$seed/.llmgate-vm/hostname"
	chmod 0600 "$seed/.llmgate-vm/hostname"
	install -d -o 1000 -g 1000 -m 0750 "$seed/dev"
	install -d -o 1000 -g 1000 -m 0700 "$seed/dev/.ssh"
	install -o 1000 -g 1000 -m 0600 "$RUN/client.pub" "$seed/dev/.ssh/authorized_keys"
	# 仓库声明系统依赖的脚本：记次数、验 sudo，打印一行供日志核对。它先等 ~/setup-go 出现（最多 300 秒），测试据此
	# 确认它在后台跑的时候开机已经完成；~/setup-go 在数据盘上，之后的启动不再等。
	install -d -o 1000 -g 1000 -m 0755 "$seed/dev/workspace" "$seed/dev/workspace/.llmgate"
	cat >"$seed/dev/workspace/.llmgate/setup.sh" <<'EOF'
#!/bin/sh
set -e
i=0
while [ ! -e "$HOME/setup-go" ] && [ $i -lt 1500 ]; do sleep 0.2; i=$((i + 1)); done
echo "setup.sh as $(id -un) in $(pwd), DEBIAN_FRONTEND=$DEBIAN_FRONTEND"
sudo -n true
echo run >>"$HOME/setup-count"
EOF
	chown 1000:1000 "$seed/dev/workspace/.llmgate/setup.sh"
	chmod 0755 "$seed/dev/workspace/.llmgate/setup.sh"
	rm -f "$RUN/data.ext4"
	truncate -s "${DATA_GIB}G" "$RUN/data.ext4"
	mke2fs -q -t ext4 -d "$seed" "$RUN/data.ext4"
	rm -rf "$seed"
}

# ---- tap 与 vsock 监听 ----
ip tuntap add dev "$TAP" mode tap
ip addr add "$HOST_IP/30" dev "$TAP"
ip link set "$TAP" up

VSOCK_LOG=$RUN/vsock.log
: >"$VSOCK_LOG"
python3 - "$RUN/v.sock_10240" "$VSOCK_LOG" <<'EOF' &
import socket, sys
path, out = sys.argv[1:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(4)
while True:
    c, _ = s.accept()
    c.settimeout(5)
    data = b""
    try:
        while not data.endswith(b"\n") and len(data) < 256:
            chunk = c.recv(256)
            if not chunk:
                break
            data += chunk
    except OSError:
        pass
    with open(out, "ab") as f:
        f.write(data)
    c.close()
EOF
pids+=($!)

# ---- 启动一台 VM ----
FC_PID=
boot() { # boot <内核命令行里 ip= 的主机名段>
	local name=$1 args
	args="reboot=k panic=1 8250.nr_uarts=0 quiet net.ifnames=0"
	if [ "${SERIAL:-0}" = 1 ]; then args="reboot=k panic=1 console=ttyS0 net.ifnames=0"; fi
	args+=" ip=$GUEST_IP::$HOST_IP:$NETMASK:$name:eth0:off:$DNS1:$DNS2"
	# Firecracker 自己创建 API socket 与 vsock 的 uds_path，上次运行留下的文件会让它启动失败（vmd 同样要先删）。
	rm -f "$RUN/api.sock" "$RUN/v.sock"
	python3 - "$RUN" "$IMAGE_DIR/vmlinux" "$args" "$TAP" "$GUEST_MAC" "$VCPUS" "$MEM_MIB" <<'EOF'
import json, sys
run, kernel, args, tap, mac, vcpus, mem = sys.argv[1:]
drive = lambda i, p, root: {"drive_id": i, "path_on_host": p, "is_root_device": root, "is_read_only": False,
                            "cache_type": "Writeback", "io_engine": "Sync"}
cfg = {
    "boot-source": {"kernel_image_path": kernel, "boot_args": args},
    "drives": [drive("system", run + "/system.ext4", True), drive("data", run + "/data.ext4", False)],
    "machine-config": {"vcpu_count": int(vcpus), "mem_size_mib": int(mem), "smt": False},
    "network-interfaces": [{"iface_id": "eth0", "guest_mac": mac, "host_dev_name": tap}],
    "vsock": {"guest_cid": 3, "uds_path": run + "/v.sock"},
}
json.dump(cfg, open(run + "/vm.json", "w"), indent=1)
EOF
	: >"$RUN/firecracker.log"
	BOOT_T0=$(date +%s.%N)
	"$FC_BIN" --api-sock "$RUN/api.sock" --config-file "$RUN/vm.json" --enable-pci \
		--log-path "$RUN/firecracker.log" --level Warning >>"$RUN/serial.log" 2>&1 </dev/null &
	FC_PID=$!
	pids+=("$FC_PID")
	local i
	for ((i = 0; i < BOOT_TIMEOUT * 2; i++)); do
		if ! kill -0 "$FC_PID" 2>/dev/null; then
			bad "Firecracker 在 SSH 就绪前退出"
			tail -n 5 "$RUN/firecracker.log" | sed 's/^/        /'
			return 1
		fi
		if vm true 2>/dev/null; then
			ok "启动到 SSH 可登录用了 $(python3 -c "import sys; print(f'{float(sys.argv[2]) - float(sys.argv[1]):.1f}s')" "$BOOT_T0" "$(date +%s.%N)")"
			return 0
		fi
		sleep 0.5
	done
	bad "SSH 在 ${BOOT_TIMEOUT}s 内没有就绪"
	return 1
}

SSH_OPTS=(-i "$RUN/client" -o IdentitiesOnly=yes -o UserKnownHostsFile="$RUN/known_hosts" -o GlobalKnownHostsFile=/dev/null
	-o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519 -o BatchMode=yes -o ConnectTimeout=3 -o LogLevel=ERROR)
vm() { ssh "${SSH_OPTS[@]}" "dev@$GUEST_IP" "$@"; }

# wait_exit <秒>：等 Firecracker 自己退出，退出码放进 EXIT_RC（超时为 timeout）。不能在 $(...) 里调用：
# 子 shell 等不到父 shell 的子进程。
EXIT_RC=
wait_exit() {
	local i
	EXIT_RC=timeout
	for ((i = 0; i < $1 * 10; i++)); do
		if ! kill -0 "$FC_PID" 2>/dev/null; then
			EXIT_RC=0
			wait "$FC_PID" || EXIT_RC=$?
			return 0
		fi
		sleep 0.1
	done
}

# wait_setup：等 llmgate-vm-setup.service 跑完（Type=exec，脚本跑的时候是 active，结束后是 inactive / failed）。
wait_setup() {
	local i s
	for ((i = 0; i < 120; i++)); do
		s=$(vm systemctl is-active llmgate-vm-setup.service || true)
		case $s in inactive | failed) return 0 ;; esac
		sleep 0.5
	done
}

# after_home <单元>：单元要求 /home 挂好（RequiresMountsFor）且排在 llmgate-vm-init 之后时输出 yes。
after_home() {
	vm "systemctl show -p RequiresMountsFor --value $1 | tr ' ' '\n' | grep -qx /home &&
		systemctl show -p After --value $1 | tr ' ' '\n' | grep -qx llmgate-vm-init.service && echo yes" || true
}

########################################################################################################
note "第 1 次启动：新建 VM（系统盘来自镜像并撑到 ${SYSTEM_GIB} GiB，数据盘 ${DATA_GIB} GiB 稀疏文件 + 种子）"
make_system_disk
make_data_disk
boot "$NAME_CMDLINE"

presented=$(ssh-keyscan -t ed25519 "$GUEST_IP" 2>/dev/null | ssh-keygen -lf - | awk '{ print $2 }' || true)
check "guest 出示的主机公钥 = 种子里设备生成的那把" "$HOSTKEY_FP" "$presented"
check "登录用户与 uid/gid" "dev 1000 1000" "$(vm 'echo $(id -un) $(id -u) $(id -g)')"
if vm sudo -n true; then ok "dev 免密 sudo"; else bad "dev 免密 sudo"; fi
# 仓库的 .llmgate/setup.sh 靠 apt 装系统依赖：apt 与它校验签名用的 keyring 都要在。
check "apt 与 Ubuntu 归档 keyring" "apt ok" "$(vm 'command -v apt-get >/dev/null && test -s /usr/share/keyrings/ubuntu-archive-keyring.gpg && echo apt ok')"
check "/home 是数据盘" "/dev/vdb ext4" "$(vm findmnt -n -o SOURCE,FSTYPE /home | xargs)"
check "/home 与家目录的属主和权限" "755 root 1000 dev" "$(vm "stat -c '%a %U' /home; stat -c '%u %U' /home/dev" | xargs)"
check "主机名取内核命令行 ip=" "$NAME_CMDLINE" "$(vm hostname)"
check "/etc/hostname" "$NAME_CMDLINE" "$(vm cat /etc/hostname)"
check "127.0.1.1 解析到本机名" "127.0.1.1" "$(vm getent hosts "$NAME_CMDLINE" | awk '{ print $1 }')"
check "DNS 取 ip= 的两段" "nameserver $DNS1 nameserver $DNS2" "$(vm grep ^nameserver /etc/resolv.conf | xargs)"
check "eth0 地址" "$GUEST_IP/30" "$(vm ip -4 -o addr show dev eth0 | awk '{ print $4 }')"
check "默认路由" "default via $HOST_IP dev eth0" "$(vm ip -4 route show default | awk '{ print $1, $2, $3, $4, $5 }')"
check "内核版本" "$LINUX_VERSION" "$(vm uname -r)"
check "版本标记 /etc/llmgate-vm-release" "lgvm1{$IMAGE_VERSION|}lgvm1" "$(vm cat /etc/llmgate-vm-release)"
echo "      guest /proc/cmdline：$(vm cat /proc/cmdline)"

# sshd 的有效配置
sshd_t=$(vm sudo -n sshd -T 2>/dev/null || true)
for kv in "allowtcpforwarding yes" "allowstreamlocalforwarding yes" "passwordauthentication no" \
	"kbdinteractiveauthentication no" "permitrootlogin no" "maxsessions 64" "maxstartups 64:30:256" \
	"hostkey /home/.llmgate-vm/ssh_host_ed25519_key" "authenticationmethods publickey" "x11forwarding no"; do
	if grep -qxF "$kv" <<<"$sshd_t"; then ok "sshd -T：$kv"; else bad "sshd -T 没有 [$kv]：$(grep -E "^${kv%% *} " <<<"$sshd_t" | xargs)"; fi
done
check "sshd 只有一把主机密钥" "1" "$(grep -c '^hostkey ' <<<"$sshd_t")"
check "系统盘上没有生成主机密钥" "" "$(vm 'ls /etc/ssh/ssh_host_* 2>/dev/null' || true)"
check "ssh.socket 未启用（sshd 常驻、排在 init 之后）" "disabled" "$(vm systemctl is-enabled ssh.socket || true)"
check "预置的 github.com / gitlab.com 主机公钥" "6" "$(vm ssh-keygen -lf /etc/ssh/ssh_known_hosts | grep -cE ' (github|gitlab)\.com ')"

# 转发：direct-tcpip（ssh -W）、本地 streamlocal（-L 到 guest 的 Unix socket）、远程 TCP（-R）。
check "direct-tcpip（ssh -W 到 guest 的 127.0.0.1:22）" "SSH-2.0" \
	"$( (sleep 2) | timeout 10 ssh "${SSH_OPTS[@]}" -W 127.0.0.1:22 "dev@$GUEST_IP" 2>/dev/null | head -c 7 || true)"
vm 'rm -f /tmp/lgvm-fwd.sock; nohup python3 -c "
import os, socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(\"/tmp/lgvm-fwd.sock\"); s.listen(1); s.settimeout(30)
c, _ = s.accept(); c.sendall(b\"streamlocal-ok\\n\"); c.close(); os.unlink(\"/tmp/lgvm-fwd.sock\")
" </dev/null >/dev/null 2>&1 &'
sleep 1
ssh "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes -N -L "$RUN/fwd.sock:/tmp/lgvm-fwd.sock" "dev@$GUEST_IP" &
fwd_pid=$!
pids+=("$fwd_pid")
got=
for _ in $(seq 1 20); do
	[ -S "$RUN/fwd.sock" ] && got=$(python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1]); print(s.recv(64).decode().strip())' "$RUN/fwd.sock" 2>/dev/null) && break
	sleep 0.3
done
check "streamlocal 转发（-L 到 guest 的 Unix socket）" "streamlocal-ok" "$got"
kill "$fwd_pid" 2>/dev/null || true
python3 - "$RUN/tcp.port" <<'EOF' &
import socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1); s.settimeout(30)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
c, _ = s.accept(); c.sendall(b"remote-ok\n"); c.close()
EOF
pids+=($!)
for _ in $(seq 1 20); do [ -s "$RUN/tcp.port" ] && break; sleep 0.1; done
ssh "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes -N -R "127.0.0.1:18080:127.0.0.1:$(cat "$RUN/tcp.port")" "dev@$GUEST_IP" &
rfwd_pid=$!
pids+=("$rfwd_pid")
got=
for _ in $(seq 1 20); do
	got=$(vm 'timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/18080 && head -n 1 <&3"' 2>/dev/null) && [ -n "$got" ] && break
	sleep 0.3
done
check "远程 TCP 转发（-R）" "remote-ok" "$got"
kill "$rfwd_pid" 2>/dev/null || true

# 时间同步：有 KVM PTP 时钟（宿主时钟源是 TSC 的裸机节点）就用 PHC refclock；嵌套虚拟化等宿主不支持
# KVM_HC_CLOCK_PAIRING 时没有这个设备，init 退回 NTP 池（chronyd 不能因缺设备而起不来）。
kvm_ptp=$(vm 'for d in /sys/class/ptp/ptp*; do [ "$(cat "$d/clock_name" 2>/dev/null)" = "KVM virtual PTP" ] && echo "/dev/${d##*/}"; done; true' || true)
check "chronyd 在运行" "active" "$(vm 'systemctl is-active chrony.service' || true)"
if [ -n "$kvm_ptp" ]; then
	ok "guest 有 KVM PTP 时钟 $kvm_ptp"
	refclock=
	for _ in $(seq 1 30); do
		refclock=$(vm chronyc -n sources 2>/dev/null | awk '$1 ~ /^#/ && $2 == "PHC0" { print $1 }' || true)
		[ "$refclock" = "#*" ] && break
		sleep 1
	done
	check "chrony 选中 PHC refclock" "#*" "$refclock"
else
	echo "      guest 没有 KVM PTP 时钟（本机宿主时钟源：$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)）；guest 内核日志："
	vm 'sudo -n dmesg | grep -iE "ptp|vmclock|clock_pairing"' 2>/dev/null | sed 's/^/        /' || true
	check "没有 PTP 时退回 NTP 池" "pool ntp.ubuntu.com iburst maxsources 4" \
		"$(vm 'grep -h ^pool /run/llmgate-vm/chrony/*.conf' 2>/dev/null || true)"
fi

# 内核配置（/proc/config.gz）：片段每一项都 =y
missing=$(vm 'zcat /proc/config.gz' | python3 -c '
import sys
have = set(l.strip() for l in sys.stdin)
want = [l.strip() for l in open(sys.argv[1]) if l.startswith("CONFIG_")]
print(" ".join(w for w in want if w not in have))' "$HERE/kernel/llmgate.config" || echo 读不到)
check "guest /proc/config.gz 含片段全部项" "" "$missing"

# systemd 状态与缺省不启用的服务。setup.sh 这时还在等 ~/setup-go：它在后台跑，开机照样完成。
state=$(vm 'timeout 60 systemctl is-system-running --wait' || true)
check "systemd 状态（setup.sh 还在后台跑）" "running" "$state"
[ "$state" = running ] || vm 'systemctl --failed --no-legend; systemctl list-jobs --no-legend' || true
check "llmgate-vm-setup.service 在后台跑" "active" "$(vm 'systemctl is-active llmgate-vm-setup.service' || true)"
check "docker 缺省不启用" "disabled disabled disabled" \
	"$(vm 'systemctl is-enabled docker.service docker.socket containerd.service' | xargs || true)"
check "sshd 与 init 已启用" "enabled enabled enabled" \
	"$(vm 'systemctl is-enabled ssh.service llmgate-vm-init.service llmgate-vm-setup.service' | xargs || true)"

# 数据盘上的服务排在 /home 挂好之后（drop-in）；llmgate-devd.service 由设备后装，用一个临时单元验 drop-in 照样生效。
for u in docker.service containerd.service; do
	check "$u 要求 /home 挂好、排在 llmgate-vm-init 之后" "yes" "$(after_home "$u")"
done
vm 'printf "[Service]\nExecStart=/bin/true\n" | sudo -n tee /etc/systemd/system/llmgate-devd.service >/dev/null && sudo -n systemctl daemon-reload' || true
check "后装的 llmgate-devd.service 要求 /home 挂好、排在 llmgate-vm-init 之后" "yes" "$(after_home llmgate-devd.service)"
vm 'sudo -n rm -f /etc/systemd/system/llmgate-devd.service && sudo -n systemctl daemon-reload' || true

# 首次启动的 setup.sh：放行，等它跑完
vm 'touch ~/setup-go'
wait_setup
check "setup.sh 首启跑了一次" "1" "$(vm 'wc -l < ~/setup-count' 2>/dev/null || echo 0)"
check "setup.sh 标记" "rc=0" "$(vm 'head -n 1 /var/lib/llmgate-vm/setup.done' 2>/dev/null || true)"
check "setup.sh 日志" "setup.sh as dev in /home/dev/workspace, DEBIAN_FRONTEND=noninteractive" \
	"$(vm 'grep "^setup.sh as" /var/log/llmgate-vm/setup.log' || true)"

# 扩容：根文件系统已长到系统盘文件大小（SYSTEM_GIB）
root_bytes=$(vm 'df -B1 --output=size / | tail -n 1' | xargs || true)
disk_bytes=$(stat -c %s "$RUN/system.ext4")
img_bytes=$(stat -c %s "$IMAGE_DIR/rootfs.ext4")
# df 的容量不含元数据，比盘文件小几个百分点；扩过之后应超过盘文件的 90%（镜像文件本身远小于 SYSTEM_GIB）。
if [ "${root_bytes:-0}" -gt $((disk_bytes / 10 * 9)) ]; then
	ok "根文件系统在线扩到系统盘大小（df $((root_bytes >> 20)) MiB，系统盘 $((disk_bytes >> 20)) MiB，镜像文件 $((img_bytes >> 20)) MiB）"
else
	bad "根文件系统没扩：df $((${root_bytes:-0} >> 20)) MiB"
	vm 'sudo -n journalctl -b -u llmgate-vm-init.service -o cat --no-pager' | sed 's/^/        /' || true
fi
home_before=$(vm 'df -B1 --output=size /home | tail -n 1' | xargs || true)
echo "      资源：$(vm 'free -m | awk "/^Mem:/ { print \"内存 \" \$2 \" MiB，已用 \" \$3 \" MiB\" }"')；根 $(vm 'df -h --output=used / | tail -n 1' | xargs) 已用"

# Docker：手工启用后能起来，数据目录在数据盘
if vm 'sudo -n systemctl start docker.service' 2>/dev/null; then
	check "docker 数据目录在数据盘" "/home/.docker-data" "$(vm 'sudo -n docker info --format "{{.DockerRootDir}}"' 2>/dev/null || true)"
	vm 'sudo -n journalctl -u docker.service --no-pager -o cat | grep -iE "level=(warning|error)" | head -n 5' | sed 's/^/      docker: /' || true
	vm 'sudo -n systemctl stop docker.service docker.socket containerd.service' || true
else
	bad "docker.service 启动失败：$(vm 'sudo -n journalctl -u docker.service --no-pager -o cat | tail -n 5' || true)"
fi

note "guest 重启：reboot=k 让 Firecracker 退出（vmd 的包装据此重新拉起）"
vm 'sudo -n systemctl reboot' >/dev/null 2>&1 || true
wait_exit 60
check "Firecracker 在 guest 重启时退出" "0" "$EXIT_RC"
check "重启不发关机通知" "" "$(cat "$VSOCK_LOG")"

########################################################################################################
note "第 2 次启动：数据盘文件扩大 4 GiB，内核命令行不带主机名（退回 .llmgate-vm/hostname）"
truncate -s +4G "$RUN/data.ext4"
boot ""
home_after=$(vm 'df -B1 --output=size /home | tail -n 1' | xargs || true)
if [ "$home_after" -gt $((home_before + (3 << 30))) ]; then ok "数据盘在线扩容（$((home_before >> 20)) → $((home_after >> 20)) MiB）"; else bad "数据盘没扩：$home_before → $home_after"; fi
check "主机名退回数据盘上的 hostname" "$NAME_SEED" "$(vm hostname)"
wait_setup
check "同一块系统盘不重跑 setup.sh" "1" "$(vm 'wc -l < ~/setup-count')"
check "数据盘内容保留（authorized_keys 未变）" "$(cat "$RUN/client.pub")" "$(vm 'cat ~/.ssh/authorized_keys')"

note "管理员停止：SendCtrlAltDel → guest 走重启流程 → Firecracker 退出"
curl -fsS --unix-socket "$RUN/api.sock" -X PUT http://localhost/actions \
	-H 'Content-Type: application/json' -d '{"action_type":"SendCtrlAltDel"}' >/dev/null && ok "SendCtrlAltDel 已发出" || bad "SendCtrlAltDel 请求失败"
wait_exit 60
check "Firecracker 在 Ctrl+Alt+Del 后退出" "0" "$EXIT_RC"
check "Ctrl+Alt+Del 不发关机通知" "" "$(cat "$VSOCK_LOG")"

########################################################################################################
note "第 3 次启动：重建系统盘（换成镜像的新拷贝），setup.sh 应再跑一次；然后 guest 关机"
make_system_disk
boot "$NAME_CMDLINE"
wait_setup
check "重建系统盘后 setup.sh 再跑一次" "2" "$(vm 'wc -l < ~/setup-count')"
check "重建后主机公钥不变" "$HOSTKEY_FP" "$(ssh-keyscan -t ed25519 "$GUEST_IP" 2>/dev/null | ssh-keygen -lf - | awk '{ print $2 }')"

vm 'sudo -n systemctl poweroff' >/dev/null 2>&1 || true
for _ in $(seq 1 300); do [ -s "$VSOCK_LOG" ] && break; sleep 0.1; done
check "关机钩子经 vsock 通知节点" "poweroff" "$(tr -d '\n' <"$VSOCK_LOG")"
wait_exit 10
if [ "$EXIT_RC" = timeout ]; then
	echo "      guest 关机后 Firecracker 10s 内没有自行退出，由包装（这里是测试脚本）结束它"
	kill -TERM "$FC_PID" 2>/dev/null || true
	wait_exit 10
	[ "$EXIT_RC" != timeout ] || { kill -KILL "$FC_PID" 2>/dev/null || true; wait_exit 5; }
else
	echo "      guest 关机后 Firecracker 自行退出（退出码 $EXIT_RC）"
fi

########################################################################################################
note "结果：$pass 项通过，$fail 项失败"
if [ "${SERIAL:-0}" = 1 ]; then echo "串口日志：$RUN/serial.log"; fi
[ "$fail" -eq 0 ]
