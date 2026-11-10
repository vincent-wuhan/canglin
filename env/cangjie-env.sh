#!/usr/bin/env bash
# PT10 本机构建环境（Intel Mac / cjc 1.1.0-beta.25）。
#
# 用法：source env/cangjie-env.sh && cd cli && cjpm test
#
# stdx 取中心仓 stdx-1.1.0 包里的 darwin_x86_64_cjnative 目标：
# 其 package.json 标 cjc_version = 1.1.0-beta.25，与本机工具链同源；
# 且同时含 mariadb 需要的 crypto.keys / crypto.digest / encoding.url
# 与 opengauss-driver 需要的 net.tls.common —— 一个模块里同时依赖两个适配器时
# 只能共用这一份 stdx（发行包 1.0.0.1 缺 net.tls.common，且为 cjc 1.0.0 构建；
# stdx-1.2.0 的 crypto.keys API 与 mariadb master 不兼容）。
export CANGJIE_PACKAGE_PATH="$HOME/.cjpm/repository/source/default/stdx-1.1.0/target/darwin_x86_64_cjnative/static"
export CANGJIE_STDX_PATH="$CANGJIE_PACKAGE_PATH/stdx"
export LIBRARY_PATH="$HOME/openssl3/lib"
export DYLD_LIBRARY_PATH="$HOME/openssl3/lib"
source "$HOME/cangjie-sdk/envsetup.sh"
