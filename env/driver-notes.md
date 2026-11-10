# 驱动/环境备忘

canglin POC 测试矩阵实测记录（macOS arm64 / Docker 28.4 colima 后端，2026-11-09）。

## 最终可用组合（docker compose ps 全 healthy）

| 服务 | 镜像 tag | 端口 | 连接参数 | 验证 |
|---|---|---|---|---|
| mysql | `mysql:8.4` | 3306 | root / canglin123 / canglin_src | `SELECT COUNT(*) FROM canglin_src.src_users` = **10000**（note NULL 100 行） |
| pg | `postgres:16` | 5432 | postgres / canglin123 / canglin_src | `dst_users` 空表就绪，列与 src_users 对齐 |
| opengauss | `opengauss/opengauss:7.0.0-RC1` | 5433→5432 | omm 系统内用户；容器内 `su - omm -c gsql` | openGauss-lite 7.0.0-RC1 build 10d38387，`gsql 'select 1'` 通过 |

openGauss 初始密码为 `GS_PASSWORD=Canglin@123`（compose 内）；首次进入用 `docker exec -it canglin-opengauss su - omm` 后 `gsql -d postgres`。PG 协议端口对外 5433。

**远程访问（PT8 注意）**：容器 `pg_hba.conf` 实测含 `host all all 0.0.0.0/0 md5`，即宿主机 TCP 5433 可达（nc 验证通过）、md5 认证放行；但 omm 默认禁止远程登录，驱动侧需先 `CREATE USER ... PASSWORD` 或改用镜像已有账号；本机暂无 psql 客户端，驱动连通性测试可在容器内或装 psql 后进行。

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

## Intel Mac 上的 Cangjie SDK（PT6 实测，2026-11-11）

官方 1.0.5 只发布 `cangjie-sdk-mac-aarch64-1.0.5.tar.gz`（无 mac-x64），**Intel 机器跑不了**。
可用的 x64 包是 `cangjie-sdk-mac-x64-1.1.0-beta.25.tar.gz`（280256419 字节，sha256
`b0b3a8208f883a62ce36e51ce9e3b30c303a5809bd1bef6c4d9381f5da5a3a8b`）：

```
https://cangjie-lang.cn/v1/files/auth/downLoad?nsId=142267&fileName=cangjie-sdk-mac-x64-1.1.0-beta.25.tar.gz&objectKey=69cb71666e8ed61e6e07fd41
```

解压后 `source <解压目录>/envsetup.sh`：`cjc --version` = Cangjie Compiler 1.1.0-beta.25 (cjnative)
x86_64-apple-darwin；`cjpm --version` = 1.1.0-beta.25。仓库里 cjpm.toml 的 `cjc-version` 仍写 1.0.5
（cjpm 不因工具链更新而报错）。

### 1.1.0-beta.25 校准坑（PT6 实测）

- **cjpm 包名只能是标识符**：`driver-api`、`driver.api` 均被拒（`the 'name' field ... is wrong, the example is 'cjDemo'`）。
- **仓颉包名必须与 cjpm name 一致**：`src/` 根包名 == cjpm name，`src/<子目录>/` 包名 == cjpm name + `.<子目录>`
  （否则报 "the package name in ... is wrong, the right name should be ..."）。
  故 `drivers/driver-api` 用 cjpm name `driver`，源码包名 `driver.api`，下游导入写 `import driver.api.*`，
  依赖写法 `driver = { path = "../driver-api" }`（已实测下游模块可正常 import + 编译）。
- **标准库没有 `Result`/`Ok`/`Err`**：实测 std 各包均未导出 Ok/Err 构造器（`import std.core.*` 也没有）。
  任务书草图里的 `Result<T, E>` 需自建——已在 `driver.api` 定义（`Ok`/`Err`）。
- **struct/enum 没有默认 toString**：`println(struct)` 编译报错 "'toString' is not a member of struct"。
  要打印就自己 `extend X <: ToString`（struct 已验证可行），`ToString` 对 enum 同样可行。
- **`StringBuilder.append` 返回 Unit，不能链式调用**：`sb.append(a).append(b)` 编译失败，须分行写。

## MySQL 适配器：mysqlclient4cj 接入（PT7 实测，2026-11-11）

### 接入方式与版本

- 社区库：**mysqlclient4cj**（Cangjie-SIG，<https://gitcode.com/Cangjie-SIG/mysqlclient4cj>），
  即仓颉版 MariaDB/MySQL CDBC 驱动，cjpm 包名 `mariadb`。
- 版本：**tag 2.0.2**（commit `09cc30a4`）。master 的 `cjc-version` 要求 1.1.0，
  高于本机工具链 1.1.0-beta.25，故锁 2.0.2。
- 接入方式：**源码依赖**（中心仓未收录该包），写在 `drivers/driver-mysql/cjpm.toml`：
  `mariadb = { git = "https://gitcode.com/Cangjie-SIG/mysqlclient4cj.git", tag = "2.0.2" }`；
  `cjpm.lock` 固定到 commitId。
- 构建前置：`mariadb` 的 cjpm.toml 用 `${CANGJIE_STDX_PATH}` 引用 stdx 静态库，
  故构建前必须 `export CANGJIE_STDX_PATH=<stdx 发行包>/static/stdx`
  （本机：`$HOME/cangjie-stdx/darwin_x86_64_llvm/static/stdx`）。
  stdx 的 crypto 包运行时还需要 **OpenSSL 3**（`libssl.3.dylib` / `libcrypto.3.dylib`）：
  本机 macOS 12 只有 OpenSSL 1.1.1 / LibreSSL，缺库时驱动在 `ds.connect()` 处直接 abort
  （"Check failed: index < funcTableSize"），须自行安装 OpenSSL 3。

### 关键 API（校准结论）

- 驱动实例：包级语句 `DriverManager.register("mariadb", MariaDBDriver())` 完成注册，
  而 `MariaDBDriver.init()` 是 protected —— 只能 `DriverManager.getDriver("mariadb")` 取用；
  **必须 import `mariadb.cdbc`** 才会触发该包级注册，否则 getDriver 返回 None。
- 连接：`drv.open(url, opts)` 要求 URL scheme 为 `mariadb`；参数走 opts（键名 `username` /
  `password` / `database` / `ssl.mode` / `prepare.mode` 等，常量在 protected package
  `mariadb.connection` 内，下游只能写字面量）。`ds.connect()` 返回 `std.database.sql.Connection`。
- 查询：`conn.prepareStatement(sql).query()` → `QueryResult`；`rs.columnInfos` 给出列名与
  **仓颉类型名**，`rs.getOrNull<T>(index)` 按 T 取值（index 从 1 起）。
- 元数据：information_schema 查询可用服务端预编译 + 绑定参数
  （`stmt.set<String>(index, value)`），实测 SCHEMATA / TABLES / COLUMNS 均可用。
- 异常：驱动的 `mariadb.connection` / `mariadb.protocol` 是 **protected package**，
  异常类型下游 import 不到 —— 只能按异常**消息**归类到 driver.api 的四类 DbError。
- 仓颉侧：`import std.database.sql.Connection as SqlConnection` 可给 std 类型起别名，
  用来避开与 `driver.api.Connection` 的同名冲突。

### 类型口径与映射

- 驱动侧类型名是仓颉类型：Int64 / Float64 / String / DateTime / Array<Byte>。
  MySQL 协议把 TEXT 与 BLOB 都编码为 0xFC，驱动无法区分，故适配器统一记为 `TEXT`，
  真正的二进制靠 UTF-8 解码失败识别（保留为字节）。
- `RawCell` 无日期变体：DATETIME 在适配层以 `yyyy-MM-dd HH:mm:ss` 文本承载，
  再由 `cell_map.cj` 还原成 `kernel.record.Column.Date`。
- 结果集列类型名与 information_schema 的 DATA_TYPE 口径对齐
  （BIGINT / VARCHAR / DOUBLE / TEXT / DATETIME）。

### 环境偏差与坑（必须声明）

- **Docker Desktop 在本机不可用**（引擎启动 panic：`engines/running_engine.go:111`，
  "no connected VM"）。PT7 的 L2 测试改用**原生 MySQL 8.0.28**（127.0.0.1:3306，
  root/canglin123，库 canglin_src，按 `env/init/01-mysql.sql` 灌入 10000 行、100 行 NULL note）
  —— 端点、账号、schema、种子数据与 docker compose 矩阵完全一致，L2 用例**真实执行并通过**，
  并非跳过。
- 仓颉 1.1.0-beta.25 **没有 `defer` 语法**（`defer` 未声明），测试里连接在用例末尾显式关闭。
- cjpm 只对以 `_test.cj` 结尾的文件注入 unittest 宏（`@Assert` / `@Fail`），
  故计划里的 `src/test/mysql_it.cj` 落为 `src/test/mysql_it_test.cj`。

