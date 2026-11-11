#!/usr/bin/env bash
# 仓颉工具链环境脚本（PT8 整改：去绝对路径硬编码 + stdx 获取路径脚本化）。
#
# 用法：
#   source env/cangjie-env.sh
#
# 做三件事：
#   1) 定位仓颉 SDK 并 source 其 envsetup.sh（设置 CANGJIE_HOME / PATH / DYLD_LIBRARY_PATH）；
#   2) 定位 stdx 预编译产物，导出 CANGJIE_PACKAGE_PATH（static 目录）与
#      CANGJIE_STDX_PATH（static/stdx 目录）——上游 opengauss-driver 的 cjpm.toml
#      用 `path-option = ["${CANGJIE_STDX_PATH}"]` 引用 stdx 静态库；
#      找不到时**脚本化获取**（建临时工程让 cjpm 把 stdx 拉进仓库缓存）后重试；
#   3) 可选：OpenSSL 3 目录加入 LIBRARY_PATH / DYLD_LIBRARY_PATH（stdx.crypto 运行时需要）。
#
# 覆盖项（全部可选；脚本内不含任何具体机器的绝对路径，路径一律由变量或运行时探测得到）：
#   CANGLIE_SDK_HOME      SDK 根目录（含 bin/cjc、envsetup.sh）
#   CANGLIE_STDX_HOME     stdx 预编译产物目录（含 static/stdx）；也可直接给 static 目录
#   CANGLIE_STDX_VERSION  stdx 版本号（默认 1.1.0，与仓库基线一致：
#                          同时含 mariadb 要的 crypto.keys 与 opengauss-driver 要的
#                          net.tls.common，且与本机 1.1.0-beta.25 工具链同源）
#   CANGLIE_CJPM_HOME     cjpm 仓库缓存根目录（默认取 CJPM_HOME / XDG 缓存 / ~/.cjpm）
#   CANGLIE_OPENSSL_HOME  OpenSSL 3 安装目录（可选）
#
# 退出码非 0 表示环境没准备好（调用方应中止构建）。

# 注意：必须 source 使用（export 到当前 shell）；直接执行只会打印诊断信息。
_canglin_env_log() { printf '[cangjie-env] %s\n' "$*"; }
_canglin_env_err() { printf '[cangjie-env][ERROR] %s\n' "$*" >&2; }

# --- 工具函数：把脚本目录当基准，避免依赖调用方的 cwd ---------------------
_canglin_env_dir() {
  (cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
}

# cjpm 仓库缓存的候选根目录（按优先级）
_canglin_env_cjpm_roots() {
  [ -n "${CANGLIE_CJPM_HOME:-}" ] && printf '%s\n' "$CANGLIE_CJPM_HOME"
  [ -n "${CJPM_HOME:-}" ] && printf '%s\n' "$CJPM_HOME"
  printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/cjpm"
  printf '%s\n' "${HOME}/.cjpm"
}

# --- 1. 定位 SDK ------------------------------------------------------------
_canglin_env_find_sdk() {
  if [ -n "${CANGLIE_SDK_HOME:-}" ]; then
    printf '%s' "$CANGLIE_SDK_HOME"
    return 0
  fi
  # PATH 上已有 cjc/cjpm（说明之前 source 过某个 SDK 的 envsetup.sh）
  local tool
  for tool in cjc cjpm; do
    tool="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$tool" ] || continue
    # 解析软链后取 SDK 根（<SDK>/bin/cjc → <SDK>）
    local resolved
    resolved="$(cd "$(dirname "$tool")" && pwd)/$(basename "$tool")"
    if [ -L "$resolved" ]; then
      resolved="$(cd "$(dirname "$resolved")" && pwd)/$(basename "$resolved")"
    fi
    printf '%s' "$(cd "$(dirname "$resolved")/.." && pwd)"
    return 0
  done
  # 仓库内自带的工具链目录
  local local_sdk
  local_sdk="$(_canglin_env_dir)/../.toolchain/cangjie-sdk"
  if [ -x "$local_sdk/bin/cjc" ]; then
    (cd "$local_sdk" && pwd)
    return 0
  fi
  # 官方 tarball 的默认安装位置（相对 $HOME 推导，不写死具体机器的绝对路径）
  local home_sdk="${HOME:-}/cangjie-sdk"
  if [ -x "$home_sdk/bin/cjc" ]; then
    (cd "$home_sdk" && pwd)
    return 0
  fi
  return 1
}

# --- 2. 定位 stdx -----------------------------------------------------------
# 输出 <static> 目录（其下有 stdx/ 子目录）
_canglin_env_find_stdx_static() {
  local explicit="${CANGLIE_STDX_HOME:-}"
  if [ -n "$explicit" ]; then
    if [ -d "$explicit/stdx" ]; then
      (cd "$explicit" && pwd)
      return 0
    fi
    if [ -d "$explicit" ]; then
      (cd "$explicit" && pwd)
      return 0
    fi
    return 1
  fi
  local root hit
  local pinned="${CANGLIE_STDX_VERSION:-1.1.0}"
  for root in $(_canglin_env_cjpm_roots); do
    [ -d "$root" ] || continue
    # 先按钉住的版本找：仓库缓存 <root>/repository/source/default/stdx-<版本>/target/<三元组>/static
    hit="$(ls -d "$root"/repository/source/default/stdx-"${pinned}"/target/*/static 2>/dev/null | head -1)"
    if [ -n "$hit" ]; then
      (cd "$hit" && pwd)
      return 0
    fi
    # 直接解压的发行包 <root>/stdx-<版本>/target/<三元组>/static
    hit="$(ls -d "$root"/stdx-"${pinned}"/target/*/static 2>/dev/null | head -1)"
    if [ -n "$hit" ]; then
      (cd "$hit" && pwd)
      return 0
    fi
  done
  # 钉住的版本没有：退而取缓存里版本号最大的（并提示可能与基线不符）
  for root in $(_canglin_env_cjpm_roots); do
    [ -d "$root" ] || continue
    hit="$(ls -d "$root"/repository/source/default/stdx-*/target/*/static 2>/dev/null | sort -V | tail -1)"
    if [ -n "$hit" ]; then
      _canglin_env_log "未找到钉住的 stdx ${pinned}，改用缓存里的 ${hit}"
      (cd "$hit" && pwd)
      return 0
    fi
    hit="$(ls -d "$root"/stdx-*/target/*/static 2>/dev/null | sort -V | tail -1)"
    if [ -n "$hit" ]; then
      _canglin_env_log "未找到钉住的 stdx ${pinned}，改用缓存里的 ${hit}"
      (cd "$hit" && pwd)
      return 0
    fi
  done
  return 1
}

# 脚本化获取 stdx：建一个只依赖 stdx 的临时工程，cjpm 会把发行包放进仓库缓存。
# 不覆盖已有缓存（幂等）：命中缓存时本函数不会被调用。
_canglin_env_fetch_stdx() {
  local version="${CANGLIE_STDX_VERSION:-1.1.0}"
  local tmp
  tmp="$(mktemp -d -t canglin-stdx-fetch)" || return 1
  mkdir -p "$tmp/src"
  cat >"$tmp/cjpm.toml" <<EOF
[package]
  cjc-version = "1.0.5"
  name = "stdxfetch"
  version = "0.1.0"
  output-type = "static"

[dependencies]
  stdx = { version = "${version}" }
EOF
  printf 'package stdxfetch\n' >"$tmp/src/stdxfetch.cj"
  _canglin_env_log "获取 stdx ${version}（cjpm 仓库缓存）……"
  (cd "$tmp" && cjpm build) >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

# --- 装配 -------------------------------------------------------------------
_canglin_env_setup() {
  local sdk
  if ! sdk="$(_canglin_env_find_sdk)"; then
    _canglin_env_err "找不到仓颉 SDK：请设置 CANGLIE_SDK_HOME 指向 SDK 根目录，或先 source <SDK>/envsetup.sh"
    return 1
  fi
  if [ ! -f "$sdk/envsetup.sh" ]; then
    _canglin_env_err "SDK 目录缺少 envsetup.sh：$sdk"
    return 1
  fi
  # shellcheck disable=SC1090
  . "$sdk/envsetup.sh"
  # cjc --version 带 ANSI 控制符，取最后一行纯文本
  local cjc_version
  cjc_version="$(cjc --version 2>/dev/null | perl -pe 's/\e\[[0-9;?]*[a-zA-Z]//g' | grep -i 'Cangjie Compiler' | head -1)"
  _canglin_env_log "SDK: $sdk [${cjc_version:-cjc ready}]"

  local stdx_static
  if ! stdx_static="$(_canglin_env_find_stdx_static)"; then
    _canglin_env_log "本地没有 stdx 预编译产物，尝试脚本化获取"
    _canglin_env_fetch_stdx || true
    stdx_static="$(_canglin_env_find_stdx_static)" || {
      _canglin_env_err "找不到 stdx 预编译产物；请设置 CANGLIE_STDX_HOME，或确认 cjpm 能访问中心仓"
      return 1
    }
  fi
  export CANGJIE_PACKAGE_PATH="$stdx_static"
  export CANGJIE_STDX_PATH="$stdx_static/stdx"
  _canglin_env_log "stdx：CANGJIE_STDX_PATH=$CANGJIE_STDX_PATH"

  # OpenSSL 3：stdx.crypto 运行时需要。
  # 必须**追加到末尾**，不能前插——前插会让 openssl3/lib 里的库抢先被装载，
  # 把 SDK 自带的运行时（C++ ABI 那套）盖掉，表现为 mysql 适配器用例 SIGSEGV。
  local openssl_lib=""
  if [ -n "${CANGLIE_OPENSSL_HOME:-}" ] && [ -d "${CANGLIE_OPENSSL_HOME}/lib" ]; then
    openssl_lib="${CANGLIE_OPENSSL_HOME}/lib"
  elif [ -d "${HOME:-}/openssl3/lib" ]; then
    openssl_lib="${HOME}/openssl3/lib"
  fi
  if [ -n "$openssl_lib" ]; then
    export LIBRARY_PATH="${openssl_lib}${LIBRARY_PATH:+:$LIBRARY_PATH}"
    # SDK 的 envsetup 可能留下首尾的空冒号（等于把 cwd 也放进装载路径），先规整再追加
    local dyld="${DYLD_LIBRARY_PATH:-}"
    dyld="${dyld#:}"
    dyld="${dyld%:}"
    export DYLD_LIBRARY_PATH="${dyld:+$dyld:}$openssl_lib"
    _canglin_env_log "OpenSSL：${openssl_lib}"
  fi

  _canglin_env_log "环境就绪：可直接 cjpm build / cjpm test"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  # 直接执行：只做诊断（并把结果打印出来），不污染调用方环境
  _canglin_env_setup
else
  _canglin_env_setup || true
fi
