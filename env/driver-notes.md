# 驱动/环境备忘

canglin POC 测试矩阵实测记录（macOS arm64 / Docker 28.4 colima 后端，2026-11-09）。

## 最终可用组合（docker compose ps 全 healthy）

| 服务 | 镜像 tag | 端口 | 连接参数 | 验证 |
|---|---|---|---|---|
| mysql | `mysql:8.4` | 3306 | root / canglin123 / canglin_src | `SELECT COUNT(*) FROM canglin_src.src_users` = **10000**（note NULL 100 行） |
| pg | `postgres:16` | 5432 | postgres / canglin123 / canglin_src | `dst_users` 空表就绪，列与 src_users 对齐 |
| opengauss | `opengauss/opengauss:7.0.0-RC1` | 5433→5432 | omm 系统内用户；容器内 `su - omm -c gsql` | openGauss-lite 7.0.0-RC1 build 10d38387，`gsql 'select 1'` 通过 |

openGauss 初始密码为 `GS_PASSWORD=Canglin@123`（compose 内）；首次进入用 `docker exec -it canglin-opengauss su - omm` 后 `gsql -d postgres`。PG 协议端口对外 5433。

## 镜像拉取（国内网络）

- 直连 Docker Hub 大概率中途 `unexpected EOF`（GFW 干扰），未配 colima mirror。
- 实测可用路径：`docker pull docker.m.daocloud.io/library/{mysql,postgres}`（**daocloud 对 `opengauss/` 命名空间 403，不代理**）；openGauss 用 `docker.1ms.run/opengauss/opengauss:<tag>`（个别 blob 会 EOF，重试即可续传）。
- 拉完 `docker tag` 回标准名，compose 文件保持官方 tag 不受影响。
- `docker.xuanyuan.me` 免费额度限流（toomanyrequests），备用。

## openGauss tag 踩坑

- `7.0.0-RC3.B025`（arm64）：**启动即挂**，`gaussdb: error while loading shared libraries: libopenblas.so.0`，镜像缺库，不可用。
- `7.0.0-RC1`（arm64）：正常，即计划原始 tag（此前以为不存在是误判——RC1 不在 Docker Hub `last_updated` 前 25 个 tag 里，翻全量列表才见）。
- Docker Hub 全量 tag（截至 2026-11）：latest / 7.0.0-RC3.B025 / RC2.B00x~B015 / RC1(.B20/.B023) / 5.0.0 / 3.1.0，全部 multi-arch(amd64+arm64)。备选顺位：7.0.0-RC1 → 7.0.0-RC2.B015 → 5.0.0。
- 健康检查：`su - omm -c 'gsql -d postgres -c "select 1"'`（镜像无 pg_isready 语义保证）；启动需 ~60s（compose 里 start_period=60s）。

## Cangjie SDK（Step 1 结果）

- 官网下载按钮无直链（CSDN API + 动态签名），最终用 Playwright 真实点击拿到 178.07MB tarball；SHA256 `e07d22584237f065b30a771b7110a87a8931334c40be3a148090944ae916ed1f`（gzip -t 通过；页面 SHA256 按钮 JS 复制，无法无头提取，未做逐字节比对）。
- 安装位置 `~/cangjie-sdk`（tarball 顶层 `cangjie/` 已 strip），`~/.zshrc` 末尾 `source ~/cangjie-sdk/envsetup.sh`（官方方式；该脚本设置 CANGJIE_HOME/PATH/DYLD_LIBRARY_PATH 并处理 quarantine）。
- 验证：`cjc --version` = Cangjie Compiler 1.0.5 (cjnative) aarch64-apple-darwin；`cjpm --version` = 1.0.5；hello-world 编译运行通过。
- 运行编译产物需在 source 过 envsetup.sh 的 shell 中（DYLD_LIBRARY_PATH 依赖 libcangjie-runtime.dylib）。

## DevEco Studio

DEFERRED：`developer.huawei.com/consumer/cn/download/` 强制 302 到 `oauth-login.cloud.huawei.com` 华为账号登录墙，无法无头下载。需人工登录下载 mac(arm) dmg 并拖入 /Applications。canglin POC 的 kernel/drivers/cli 任务不依赖它。
