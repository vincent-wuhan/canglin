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


## PT9 错误四分类 + close 幂等（2026-11-11）

### 契约放在 driver-api（两个适配器共用一份口径）

- 新增包 `driver.testkit`（`drivers/driver-api/src/testkit/error_contract.cj`）：
  - `probeErrorClassification(drv, good, wrongPassword, unreachablePort, unreachableHost, missingTableSql)`
    → 探测四类错误的归类：错误口令 / 不可达端口 / 不可达主机 / 查询不存在的表。
    每个字段是 `Option<DbError>`：Some(e)=按预期失败且类别为 e；None=**竟然成功**（契约不成立）。
  - `probeCloseIdempotency(drv, good)` → 两次 close 是否抛异常、关闭后查询/元数据是否以错误结果返回。
  - `isAuthFailed` / `isNetworkUnreachable` / `isQueryError` / `isProtocolError` 四个类别判定。
- 探针只观察适配器给出的 `DbError` **类别**，不判文案——文案→类别的映射仍是各适配器内部的事
  （issue：按需在适配器内补错误归类映射）。这样 MySQL 与 PG/openGauss 的口径由同一份契约钉住，
  不会各写一份、各漂移一份。
- MySQL 侧已实例化并跑通：`drivers/driver-mysql/src/test/mysql_it_test.cj`
  （`testErrorClassificationAgainstLiveServer` / `testCloseIdempotent`）。
- **PG/openGauss 侧待接**：模板见本 issue 附件 `pg_contract_test.cj`，
  落位 `drivers/driver-pg/src/test/pg_contract_test.cj`（包名须 `pg_driver.test`，文件名须以 `_test.cj` 结尾）；
  若 PT8 的驱动类名不是 `PgDriver`，改掉模板里的三处即可。

### PG 侧归类映射必须覆盖的文案（对照 MySQL 侧 `mysql_driver.classifyDbError`）

| 类别 | 必须能识别的文案 |
|---|---|
| AuthFailed | `password authentication failed` / `authentication failed` / `invalid password` / `role "..." does not exist` |
| NetworkUnreachable | `connection refused` / `connection timed out` / `timeout` / `could not connect` / `no route to host` / `name or service not known` / `nodename nor servname` / `failed to resolve` |
| QueryError | `does not exist` / `relation "..." does not exist` / `syntax error` / `permission denied for table` |
| ProtocolError | 其余（握手/报文格式等） |

### MySQL 侧本次补的归类缺口（PT9 实测）

- **域名解析失败原先落 ProtocolError**：驱动报 `Failed to resolve address no-such-host.invalid.`，
  既不含 "connection refused" 也不含 "failed to connect"，于是一律掉进 ProtocolError。
  spec 的「不可达主机」要求它归 NetworkUnreachable——已补 `failed to resolve` / `resolve address` /
  `name resolution` / `unknown host` / `nodename nor servname` 关键字。
  （TDD 红→绿：`testErrorClassificationAgainstLiveServer` 先 FAILED 后 PASSED。）
- 另补 `not allowed to connect` → AuthFailed（服务端拒绝来源主机访问属账号被拒，不是协议问题）。

### PG 侧当前的环境阻塞（PT9 实测，交接给 PT8）

- **opengauss-driver 编译不过**：master 分支依赖 `stdx.net.tls.common`，
  而本机只有 stdx **1.0.0.1**（`~/cangjie-stdx/darwin_x86_64_llvm`，只有 `stdx.net.tls`）——
  `cjpm build` 报 `can not find the following dependencies: stdx.net.tls.common`。
  换 0.60.5 分支则因该分支 `cjc-version = "0.53.4"`（旧依赖解析模式），
  要求在消费方 cjpm.toml 里显式声明 stdx.log / stdx.crypto.crypto / stdx.encoding.url / stdx.encoding.hex，
  而 stdx 发行包是 .cjo/.a 形态，不是可直接 path 依赖的源码包——需换 stdx 版本或 fork 驱动。
  **要拿到含 `stdx.net.tls.common` 的 stdx，得走官网交互式下载（本机无 Playwright 自动化账号链路）。**
- **openGauss 端点（5433）本机起不来**：Docker Desktop 引擎在本机恒为 stopped
  （`docker desktop status` → stopped，API 报 500 "no connected VM"），
  compose 的三容器矩阵跑不起来；PG 5432 可用 brew 原生 PostgreSQL 13.1 顶替，
  但 openGauss 没有原生替代。

## PG/openGauss 适配器：opengauss-driver 接入（PT8 实测，2026-11-11）

### 接入方式与版本

- 社区库：**opengauss-driver**（Cangjie-TPC，<https://gitcode.com/Cangjie-TPC/opengauss-driver>）。
  上游对 PostgreSQL 与 openGauss **共用一套 PG 线协议实现**，差异只在启动握手
  （`DBType.Postgres` / `DBType.OpenGauss`）——故本仓一个适配器同时承载两个端点，
  由 `cfg.driver`（`pg` / `postgres` / `opengauss`）决定注册名，进而决定握手分支。
- 版本：**master 分支 commit `169813b`**（"!34 merge master into master"）。
  cjpm 包名 `cangjie_tpc::opengauss`（上游 `organization = "cangjie_tpc"` + `name = "opengauss"`）。
- 接入方式：**源码依赖**（中心仓未收录该包），写在 `drivers/driver-pg/cjpm.toml`：
  `"cangjie_tpc::opengauss" = { git = "https://gitcode.com/Cangjie-TPC/opengauss-driver.git", branch = "master" }`。
  依赖键必须写**带 organization 前缀**的限定名，只写 `opengauss` 会被 cjpm 判为非法依赖名。
- 上游 cjpm.toml **没有 `[dependencies]`**，stdx 靠环境变量注入：
  `[target.x86_64-apple-darwin.bin-dependencies] path-option = ["${CANGJIE_STDX_PATH}"]`。
- **stdx 版本**（PT9 交接的阻塞已解）：上游 master 依赖 `stdx.net.tls.common`，
  本机 stdx **1.0.0.1** 发行包（`~/cangjie-stdx/darwin_x86_64_llvm`）没有该包。
  改用**中心仓 stdx 1.2.0 预编译包**（`~/.cjpm/repository/source/default/stdx-1.2.0/target/darwin_x86_64_cjnative/static`，
  其 package.json 标 `cjc_version = 1.1.0-beta.25`，与本机工具链同源，含 `stdx.net.tls.common`）。
  构建前置：

  ```bash
  STDX=$HOME/.cjpm/repository/source/default/stdx-1.2.0/target/darwin_x86_64_cjnative/static
  export CANGJIE_PACKAGE_PATH=$STDX
  export CANGJIE_STDX_PATH=$STDX/stdx
  export LIBRARY_PATH=$HOME/openssl3/lib
  export DYLD_LIBRARY_PATH=$HOME/openssl3/lib
  source ~/cangjie-sdk/envsetup.sh
  cd drivers/driver-pg && cjpm test
  ```

  注意 **MySQL 适配器用的是 stdx 1.0.0.1 发行包**（PT7 记录），两者不冲突：各自进程按
  `CANGJIE_PACKAGE_PATH` 解析，互不干扰。

### 上游缺陷与本地补丁（`env/patch-opengauss-driver.sh`，8 处，幂等可重放）

上游仓库未修复且未发版，cjpm 拉到的是源码缓存（`~/.cjpm/git/cangjie_tpc::opengauss/<commit>/`），
故就地打补丁。脚本对每处补丁带独立标记，重复执行只报 `[skip]`，缓存被重新拉取后重跑即可恢复。

| 补丁 | 位置 | 上游现象 | 处理 |
|---|---|---|---|
| 1 | `src/main_test.cj` | 声明 `package opengauss`，与 organization 推出的 `cangjie_tpc::opengauss` 不符 | 补齐前缀，否则 `cjpm test` 直接报 "the package name in ... is wrong" 并中止 |
| 2 | `cjpm.toml` | `output-type = "dynamic"`：包初始化早于 stdx.serialization，unittest 可执行文件启动即 SIGABRT（"funcTable is nullptr"） | 改 `static`，包初始化随静态初始化链执行 |
| 3a | `src/proto3/notice_response.cj` | `serialize()` 用 `field<HashMap<UInt8, String>>`，stdx 要求键为 String，服务端回一条 NOTICE（如 `DROP TABLE IF EXISTS` 命中不存在的表）即抛 `DataModelException("This data is not String.")` | 改 `field<String>("params", params.toString())`（与上游 ErrorResponse 的既有修法一致） |
| 3b | 同上 | `deserialize()` 还原 params | 停用还原（序列化时已退化为字符串） |
| 4 | `src/pgconn/config.cj` | `Config.toString()` 插值 `params`（HashMap）：stdx 的 HashMap 序列化扩展要求运行时实现 `std.core:Collection<Tuple<K,V>>`，SDK 1.1.0-beta.25 的 std HashMap 不满足，**插值即 SIGABRT**（`expected interface std.core:Collection<Tuple<String,String>> is not in class std.collection:HashMap<String,String>`），unittest 二进制启动即挂 | 改输出 `params.size`；顺带把口令换成固定掩码 |
| 5a/5b/5c | `src/driver/driver.cj` | 建连 DEBUG 日志与 URL 解析失败异常带完整连接串（**含口令明文**），违反 spec「密码不得写入日志」 | 新增 `maskConnStrPassword()`，把 userinfo 中的口令段落替换为 `***` |

### 类型口径与映射

- 上游 `oid2typename` 把 **oid 25(text) 与 1043(varchar) 统一归为 `SqlVarchar`**，
  未知 oid 一律回落 `SqlVarchar`——故 `query()` 路径下 TEXT 列的类型名显示为 `VARCHAR`，
  数组类型名形如 `Array<SqlBigInt>`。
  **精确类型以 `tableColumns()`（information_schema）为准**，两条路径口径差异已在测试中显式标注。
- `RawCell` 取值：布尔 → `I64(0/1)`；整型 → `I64`；real/double/decimal → `F64`；
  varbinary → `B`；其余（含日期时间）→ `S`（ISO 文本）；NULL → `N`。
- DDL/DML 也走 `query()`：上游 `simpleExec` 对无 RowDescription 的命令返回空列集，不影响调用方。
- 数组类型名还原：上游类型名 `Array<SqlXxx>` 的元素部分自下标 6 起、末尾 `>` 独占一位，
  仓颉切片右端**开区间**，故取 `[6, size - 1)`。

### 连接与协议

- URL 形态：`postgres://user:pass@host:port/db?sslmode=disable&connection_timeout=5000&read_timeout=30000`；
  openGauss 用 `opengauss://` scheme。口令按 RFC 3986 未保留字符集逐字节百分号编码。
- 上游 URL 解析器**只对 password 解码**，username 原样取用 → 账号需为不含保留字符的普通账号。
- **`sslmode=prefer` 在服务端拒绝 TLS 时不会回落到明文**（直接抛 "server refused TLS connection"），
  故 POC 显式 `sslmode=disable`；生产化需改 `verify-full` 并配置证书。
- 上游把连接串与 `Config` 打到 DEBUG 日志——补丁 4/5 后不再带口令。

### 测试布局（同一测试函数跑双端点）

- `drivers/driver-pg/src/test/pg_it_test.cj`：`testPgAndOpenGaussEndpoints` **一个测试函数**，
  用同一份端点无关用例体（`runEndpointSuite` → `runSuiteOn`）依次跑
  **PostgreSQL(5432)** 与 **openGauss(5433)**——两个端点只有连接参数不同，
  断言代码完全一致（对应 spec「上层代码驱动无关」场景）。
- PG 侧测试函数**自带 setup**：`pt8_probe_users` 建表 + 插数 + 用例末尾清理
  （compose 的 `dst_users` 是空表，PT10 保留）。
- 错误四分类与关闭幂等直接复用 PT9 的 `driver.testkit` 契约探针，
  与 MySQL 适配器**同一份断言口径**，不在适配器里另写一份。

### 环境偏差与坑（必须声明）

- **Docker 仍不可用**：本机 `docker info` → "Cannot connect to the Docker daemon"，
  Docker Desktop 引擎在本机（macOS 12.7.4 Intel）起不来 VM，上次成功运行是 2025-09-04；
  无 colima / lima / podman 备选。因此 **openGauss 端点（5433）本轮缺席**：
  - issue 要求的第一步「容器内建业务用户（omm 禁止远程登录）」**无法执行**——没有可运行的容器；
  - 共享用例体对 openGauss 端点**显式打印 `[SKIP]` 声明**并跳过数据断言
    （std.unittest 1.1.0-beta.25 仅有静态 `@Skip` 标记、无运行时 skip 入口，
    故该用例在框架计数里仍计入 PASSED——已在测试输出与交付说明中写明这一点，不做静默跳过）。
  - **PG 端点（5432）用原生 PostgreSQL 13.1 顶替** compose 的 `postgres:16`：
    127.0.0.1:5432，postgres / canglin123 / canglin_src，端点、账号、库名与 compose 矩阵一致，
    L2 用例**真实执行并通过**（非跳过）。compose 的 `dst_users` 是空表，
    故 PG 侧测试函数自带 `pt8_probe_users` 建表/插数 setup（PT10 保留 `dst_users`）。
- 仓颉 1.1.0-beta.25 **没有 `defer` 语法**，连接在用例末尾显式关闭。
- cjpm 只对以 `_test.cj` 结尾的文件注入 unittest 宏（`@Assert` / `@Fail`），
  故 PG 用例落为 `drivers/driver-pg/src/test/pg_it_test.cj`。
- 上游异常统一包成 `SqlException`，**异常类型在下游 import 不到**，
  只能按**消息**归类到 driver.api 的四类 DbError（`classifyError`）。
- 域名解析失败（`Failed to resolve address <host>`）必须归 NetworkUnreachable：
  本仓 MySQL 适配器与 PG 适配器**同一口径**（PT9 交接表列出必须覆盖的文案）。


## 跨适配器归类口径表（PT9 收口，2026-11-11）

- 口径表已从「交接文档里的清单」变成**代码**：`driver.testkit.canonicalErrorCases()`
  （`drivers/driver-api/src/testkit/error_contract.cj`），一条 = 一句错误文案 + 它必须落到的类别；
  配 `categoryOf(DbError)` 把适配器给出的错误还原成类别。
- 两个适配器各跑一遍这张表：`drivers/driver-mysql/src/test/mysql_it_test.cj` 与
  `drivers/driver-pg/src/test/pg_contract_test.cj` 的 `testCanonicalErrorMessageTable`。
  任何一边改了归类映射而没同步另一边，测试就红——避免两份映射各写一份、各漂移一份。
- 表里只放**两个适配器都可能遇到**的文案（服务端错误串、套接字层错误串）；
  驱动特有文案（如 MySQL 的 `Access denied for user`）不进表，由各自适配器的测试覆盖。
- 本轮补的映射缺口：MySQL 侧 `permission denied for table ...` 原先落到 ProtocolError，
  已改归 QueryError（权限不足是 SQL 语义错误，不是协议问题）。

### stdx 版本必须与工具链同源（ABI 实测）

- 用**为别的 cjc 版本构建**的 stdx，std.core 的接口虚表布局不一致，运行期直接崩：
  - stdx **1.0.0.1**（为 cjc 1.0.0 构建）+ cjc 1.1.0-beta.25 → 虚调用落到错误槽位，SIGSEGV
    （如 `SimpleLogger.isClosed()`）。
  - stdx **1.2.0**（为 cjc 1.2.0 构建）+ cjc 1.1.0-beta.25 → 启动即 abort：
    `expected interface std.core:Collection<Tuple<String,String>> is not in class std.collection:HashMap<String,String>`。
- 结论：stdx 必须**用本机工具链自建**（中心仓的 stdx 1.1.0 源码 `cjpm build`，
  或用发行包但确认其 `cjc_version` 与本机一致）。PT8 落地用的是
  `~/.cjpm/repository/source/default/stdx-1.2.0/target/darwin_x86_64_cjnative/static`
  （其 package.json 标 `cjc_version = 1.1.0-beta.25`，与本机同源）。
- 自建 stdx 时的坑：Apple clang 11 不接受 `-mmacosx-version-min=12.0.0`（需把 stdx 的
  deployment target 改 10.15）；缺 `cmake`/`ninja`（brew 拉不动时 pip 装）、缺 `llvm-ranlib`
  （SDK 只有 llvm-ar）；原生 FFI 静态库在 `build_temp/build/lib/`，**要拷进
  `target/release/stdx/`**，否则下游链接找不到 `-lstdx.*FFI`。
- 下游（opengauss-driver）只声明
  `[target.x86_64-apple-darwin.bin-dependencies] path-option = ["${CANGJIE_STDX_PATH}"]`，
  不会把 stdx 的 FFI 库带进最终可执行文件的链接行；自建 stdx 1.1.0 时下游还需显式补
  `link-option = "-lstdx.encoding.jsonFFI -lstdx.encoding.json.streamFFI -lstdx.crypto.keysFFI
  -lstdx.crypto.x509FFI -lstdx.net.tlsFFI -lcangjie-dynamicLoader-opensslFFI ..."`，
  运行期 `DYLD_LIBRARY_PATH` 需含 stdx 目录与 OpenSSL 3 所在目录。

### 本机端点现状复核（2026-11-11）

- **Docker 引擎仍不可用**：`docker info` → "Cannot connect to the Docker daemon"，
  `docker desktop` 子命令在本机 CLI（17.09.0-ce）里已不存在 → compose 三容器矩阵
  （MySQL/PG/openGauss）起不来，**openGauss 端点（5433）本轮仍缺席**。
- 端点用原生进程顶替（与 compose 矩阵的端点/账号/库名一致）：
  - MySQL 8.0.28 @ 127.0.0.1:3306（root/canglin123，库 canglin_src，src_users 10000 行 / 100 行 NULL note）
  - PostgreSQL 13.1 @ 127.0.0.1:5432（postgres/canglin123，库 canglin_src，**只有空表 dst_users**，
    源表 src_users 只在 MySQL 侧）

## PT10 万行同步吞吐基线（2026-11-11）

### 测量口径

- 命令：`cd cli && cjpm run --`（连接串走 `CANGLIN_MYSQL_DSN` / `CANGLIN_PG_DSN`，
  缺省即 127.0.0.1 上的 MySQL 3306 / PG 5432，库 `canglin_src`）。
- 源表 `src_users` 10000 行（id 1..10000，note 每 100 行一个 NULL），
  目标表 `dst_users`（列集合与源表一致，score/note 可空，created_at NOT NULL）。
- 作业形态：MySQLReader 分页 `SELECT ... ORDER BY id LIMIT n OFFSET m`（每页 500 行）
  → Record → Channel → PgWriter 批量 `INSERT`（每批 500 行，批内一个事务）。
- 吞吐 = 成功行数 ÷ 作业耗时（`ok * 1000 / elapsed_ms`），耗时只算作业本身，不含建连。

### 结果

| 场景 | ok | dirty | 耗时 ms | 吞吐（行/秒） |
|---|---|---|---|---|
| 万行同步（batch=500，第 1 次） | 10000 | 0 | 596 | 16778 |
| 万行同步（batch=500，第 2 次） | 10000 | 0 | 601 | 16638 |
| 万行同步（batch=500，第 3 次） | 10000 | 0 | 608 | 16447 |
| 万行同步（batch=500，第 4 次） | 10000 | 0 | 721 | 13869 |
| 万行同步（batch=200） | 10000 | 0 | 656 | 15243 |
| 万行同步（batch=1000） | 10000 | 0 | 582 | 17182 |
| 脏行变体（batch=500） | 9950 | 50 | 649 | 15331 |

- **基线取 batch=500 的一组：吞吐 1.5 万～1.7 万行/秒，作业耗时 0.58～0.72 秒。**
- 批大小只影响往返次数：500 → 1000 行/批 吞吐涨约 3%，200 行/批跌约 8%；
  再大（>2000）收益趋平，且单批事务变长、失败时逐行回退的重试成本线性上升——不作为基线。
- PG 侧 `SELECT COUNT(*) FROM dst_users` = **10000**（CLI 的 `count` 子命令同口径）。
- 峰值常驻内存：约 **46 MB**（30ms 间隔采样 `ps -o rss`，全量 1 万行只保留
  一批 500 行在管道里，故内存与行数无关、与批大小线性相关）。
- 脏行变体：`src_users_dirty` 的 score 声明为 VARCHAR，其中 id 能被 200 整除的
  **50 行**（200,400,…,10000）值为 `N/A` → 与目标列 DOUBLE PRECISION 类型错配；
  作业不中断，`ok=9950 dirty=50`，PG 侧 `dst_users_dirty` COUNT(*) = 9950。

### 环境声明（Docker 不可用）

- **Docker 引擎仍不可用**（`docker info` → Cannot connect to the Docker daemon），
  compose 三容器矩阵起不来；openGauss 端点（5433）本轮同样缺席（PT10 不依赖它）。
- 本轮 L2 用**原生 MySQL 8.0.28 + 原生 PostgreSQL 13.1** 顶替 compose 的 MySQL8/PG16，
  端点、账号、库名与 compose 矩阵完全一致（127.0.0.1:3306 / :5432，canglin123，canglin_src）。
- 因此 PT10 的 L2 用例**真实执行并通过**，不是跳过（`cjpm test` Summary: TOTAL 36 / PASSED 36 /
  SKIPPED 0 / FAILED 0）。用例里的不可达分支按 PT8 同一口径打印 `[SKIP]` 声明后跳过。
- 复现步骤：`env/init/01-mysql.sql` → `env/init/02-pg.sql` → `env/init/03-mysql-dirty.sql` →
  `env/init/04-pg-dirty.sql`，然后 `cd cli && cjpm run --`。
  ⚠️ MySQL 侧建表灌数**不能走驱动**（见下），要用 mysql 客户端执行 SQL 文件。

### PT10 新增校准坑

- **mysqlclient4cj 必须用 master 分支，不能用 tag 2.0.2**（PT7 当时锁的是 2.0.2）：
  tag 2.0.2 的 `cjc-version` 要求 1.1.0（高于本机 1.1.0-beta.25），且它构建时链接的
  stdx 静态库与 pgdriver 需要的 stdx 不是同一份。`cli` 是**第一个同时链接 mysql_driver
  与 pgdriver 的模块**，这个冲突到 PT10 才暴露：两个适配器必须共用同一份 stdx
  （stdx-1.1.0，含 mariadb 要的 crypto.keys/crypto.digest/encoding.url 与
  opengauss-driver 要的 net.tls.common）。本轮把 `drivers/driver-mysql/cjpm.toml`
  的 mariadb 依赖切到 `branch = "master"`，`cjpm.lock` 随之更新。
  本机编译环境变量见 `env/cangjie-env.sh`（`CANGJIE_PACKAGE_PATH` / `CANGJIE_STDX_PATH` /
  `LIBRARY_PATH` / `DYLD_LIBRARY_PATH` 指向 openssl3，再 source SDK 的 envsetup.sh）。
- **MySQL 适配器的 `query()` 只支持 SELECT**：上游 mysqlclient4cj 走
  `ServerPrepareStatement`，DDL/DML 会报
  "Execute non-select statements using the query method."——即 MySQL 侧建表、灌数、
  UPDATE 都**不能经驱动执行**。故脏行变体的源表用 `env/init/03-mysql-dirty.sql`
  建好，测试只读不写。PG 适配器的 `query()` 则支持 DDL/DML（simpleExec 路径），
  PG 侧建表可直接走驱动。
- **PG 事务控制语句要走简单查询协议**：`BEGIN` / `COMMIT` / `ROLLBACK` 经
  `conn.query()` 发送，失败后连接仍可用（上游 `simpleExec` → `ResultReader.close()`
  会读到 ReadyForQuery 为止），所以「整批失败 → ROLLBACK → 逐行重试」这条路是通的。
- **PG 字符长度按字符计、不按字节**：information_schema 的 `character_maximum_length`
  是字符数，仓颉 `String.size` 是字节数——判超长要用 `utf8CharCount`（数非续字节）。
- **`Float64.toString()` 固定 6 位小数**：浮点列的字面量写成 `88.500000` 而不是 `88.5`，
  PG 能收，但不等于源值的原始文本形态。
- **仓颉 lambda 必须有期望类型**：`(key: String) => ...` 这种带注解的写法编译不过，
  要写成 `let f: EnvLookup = { key => ... }`；捕获 lambda 的参数未使用会报 unused 警告。
- **`Option<T> == None` 要求 `T: Equatable`**：`Endpoint` / `SyncOptions` /
  `Array<ColumnBinding>` 都不是 Equatable，测试里判空要写成 `isNone<T>(v)` 这类泛型辅助
  （`match` 两个分支），否则报 "generic type should be used with type argument"。
- **CLI 入口**：`main(args: Array<String>): Int64` 直接收命令行参数；
  `cjpm run -- --src-table=xxx` 的 `--` 之后才是传给程序的部分。
- **std.unittest 1.1.0-beta.25 的跳过机制**：有 `@Skip` 宏（在 `std.unittest.testmacro`，
  必须写在 `@Test` **之前**），但**没有** `@Ignore`；且**没有运行时 skip 入口**——
  被跳过的用例仍计入框架 PASSED 计数，只能靠 stdout 打印 `[SKIP]` 声明留痕（与 PT8 同一口径）。
- **`cjpm test` 假成功坑可复现**：src/ 根目录没有 .cj 文件时子目录不被扫描，
  输出 `TOTAL: 0 / PASSED: 0` 且退出码 0。验收仍必须断言 `PASSED > 0`。
- **macOS 上 `/usr/bin/time` 是 SIP 保护二进制**：它会清掉子进程的 `DYLD_LIBRARY_PATH`，
  仓颉可执行文件随即报 "Library not loaded: @rpath/libcangjie-runtime.dylib"，
  峰值 RSS 测不出来（只能改用 `ps -o rss` 采样）。
- **原生 PG 实例里的 `dst_users` 曾是 2 列的旧表**（PT8 探针留下的），
  与 `env/init/02-pg.sql` 的 5 列定义不符；PT10 已按 init 脚本重建。
  PT8 的 L2 用例自带 `pt8_probe_users` 建表，不写 `dst_users`，两者互不干扰。
