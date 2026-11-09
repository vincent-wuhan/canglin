# driver-connectivity

## ADDED Requirements

### Requirement: 数据库建连
系统 SHALL 通过统一连接入口建立到 MySQL 8、PostgreSQL 16、openGauss 的连接，连接参数 SHALL 包含主机、端口、库名、用户、密码，密码不得写入日志。

#### Scenario: 三库建连成功
- **WHEN** 使用 Docker 测试矩阵实例的正确连接参数调用连接入口
- **THEN** 对 MySQL/PostgreSQL/openGauss 各返回可用连接对象

#### Scenario: 错误参数给出可区分错误
- **WHEN** 使用错误密码或不可达主机调用连接入口
- **THEN** 返回包含错误类别的失败结果（认证失败/网络不可达），而非裸异常或 panic

### Requirement: 查询执行
系统 SHALL 对已建立的连接执行任意 SELECT 语句，结果 SHALL 以驱动无关的行结构返回，覆盖整型、浮点、字符串、NULL 四类列。

#### Scenario: 查询含四类列的结果集
- **WHEN** 对测试库执行包含整型、浮点、字符串、NULL 列的 SELECT
- **THEN** 返回行数正确的驱动无关行结构，四类列值可正确读取

### Requirement: 元数据读取
系统 SHALL 读取库/表/列三级元数据：列出数据库（schema）、列出表、读取列名与类型，供下游对象树消费。

#### Scenario: 读取表与列元数据
- **WHEN** 对已建连实例请求指定 schema 的表清单及任一表的列定义
- **THEN** 返回表名列表与列名/类型映射，与测试库 DDL 一致

### Requirement: 驱动 SPI 隔离
上层 SHALL 仅依赖统一驱动接口（连接/查询/元数据），不感知具体驱动类型；更换或新增驱动 SHALL 不修改上层代码。

#### Scenario: 上层代码驱动无关
- **WHEN** 用同一上层调用分别访问 MySQL 与 PostgreSQL
- **THEN** 仅连接参数中的驱动类型标识不同，调用代码完全一致
