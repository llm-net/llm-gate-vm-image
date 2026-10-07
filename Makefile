# LLM Gate VM 镜像（Firecracker guest）的构建、测试与发布入口。流程见 docs/maintenance.md。
#
# 版本 YYMMDDHHMM-xxxx：构建时刻（本地时区，精确到分钟）+ 本仓库 HEAD 七位短哈希的末四位；工作树不干净时
# 带 -d（-d 版本只能本地测试，不能发布）。发布时先 `make print-version` 取一次，再把同一个 VERSION 显式传给
# 后面每一步——两次 make 之间分钟数可能翻页。
#
#   make print-version
#   sudo make deps                          # 构建依赖（Ubuntu 24.04 x86-64）
#   sudo make image VERSION=<版本>          # → bin/<版本>/
#   sudo make boot-test VERSION=<版本>      # 本机 KVM 开机冒烟测试
#   make manifest-entry VERSION=<版本>      # 官网签名清单的条目草稿（交给主仓签名部署）
#   GH_TOKEN=… make publish VERSION=<版本>  # 建 GitHub Release、上传 bin/<版本>/release/
#   make check                              # 脚本语法与 overlay 清单自查（不需要 root）

BUILD_STAMP := $(shell date +%y%m%d%H%M)
GIT_SUFFIX  := $(shell git rev-parse --short=7 HEAD 2>/dev/null | tail -c 5)
GIT_DIRTY   := $(shell git status --porcelain 2>/dev/null | head -n 1)
VERSION ?= $(BUILD_STAMP)-$(or $(GIT_SUFFIX),0000)$(if $(GIT_DIRTY),-d)

BIN := bin

.PHONY: print-version deps image boot-test manifest-entry publish check clean

print-version:
	@echo $(VERSION)

deps:
	bash scripts/install-deps.sh

image:
	VERSION=$(VERSION) OUT=$(BIN)/$(VERSION) bash ./build.sh

# 测试与发布针对已经构建好的目录，必须显式给 VERSION（缺省值按当前时刻算，几乎不会等于已构建的版本）。
boot-test:
	@test -n "$(filter command line environment,$(origin VERSION))" || { echo "须显式给 VERSION=<版本>" >&2; exit 2; }
	bash ./boot-test.sh $(BIN)/$(VERSION)

manifest-entry:
	@test -n "$(filter command line environment,$(origin VERSION))" || { echo "须显式给 VERSION=<版本>" >&2; exit 2; }
	@python3 -I scripts/manifest-entry.py $(BIN)/$(VERSION)/image.json

publish:
	@test -n "$(filter command line environment,$(origin VERSION))" || { echo "须显式给 VERSION=<版本>" >&2; exit 2; }
	bash scripts/publish-release.sh $(VERSION)

check:
	bash -n build.sh
	bash -n boot-test.sh
	bash -n rootfs/customize.sh
	bash -n scripts/install-deps.sh
	bash -n scripts/publish-release.sh
	bash -n rootfs/overlay/usr/lib/llmgate-vm/init
	bash -n rootfs/overlay/usr/lib/llmgate-vm/setup
	sh -n rootfs/overlay/usr/lib/systemd/system-shutdown/llmgate
	bash scripts/check-overlay.sh
	python3 -I -c 'import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' scripts/manifest-entry.py

# 只删产物目录；下载缓存与内核构建树（bin/.cache、bin/.work）留着给下次增量构建。
clean:
	find $(BIN) -mindepth 1 -maxdepth 1 ! -name .cache ! -name .work ! -name .lock -exec rm -rf {} + 2>/dev/null || true
