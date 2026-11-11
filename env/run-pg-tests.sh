#!/usr/bin/env bash
# PT8 双端点测试入口：source 工具链环境后跑 drivers/driver-pg 的 cjpm test。
# 用法: env/run-pg-tests.sh
set -eo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# SDK 的 envsetup.sh 直接读 DYLD_LIBRARY_PATH，先给空值避免 set -u 报错
export DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
# shellcheck disable=SC1091
source "$REPO/env/cangjie-env.sh"
cd "$REPO/drivers/driver-pg"
exec cjpm test "$@"
