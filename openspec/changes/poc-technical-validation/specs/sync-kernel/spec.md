# sync-kernel

## ADDED Requirements

### Requirement: Record 中立行模型
内核 SHALL 提供驱动无关的行模型：一行由有序列组成，每列 SHALL 为枚举类型（整型/浮点/字符串/字节/布尔/日期/NULL）之一，读写两侧不感知具体数据库类型系统。

#### Scenario: 列类型无损装载
- **WHEN** 将含整型、浮点、字符串、NULL 的查询行装入 Record
- **THEN** 列类型与值可完整读出，NULL 列显式可判

### Requirement: Channel 传输管道
内核 SHALL 提供有界内存管道连接读侧与写侧，满时读侧阻塞、空时写侧阻塞，MUST 不丢行、不重复行。

#### Scenario: 有界背压
- **WHEN** 读侧生产速度持续高于写侧消费速度且管道达到容量上限
- **THEN** 读侧阻塞等待，全程无行丢失或重复

### Requirement: Reader/Writer SPI
内核 SHALL 定义 Reader 与 Writer 接口：Reader 负责从源拉取行并写入 Channel，Writer 负责从 Channel 取出并写入目标；MUST 可独立替换单侧实现。

#### Scenario: 双侧插件独立替换
- **WHEN** 以 MySQL Reader + PostgreSQL Writer 组合，替换其中任一侧为内存假实现
- **THEN** 另一侧无需修改即可继续工作

### Requirement: 作业执行与统计
内核 SHALL 以单作业形态驱动 Reader-Channel-Writer 流水线直至完成，SHALL 输出成功行数、失败行数与耗时统计。

#### Scenario: 万行同步完整完成
- **WHEN** 执行 MySQL→PostgreSQL 的 1 万行同步作业
- **THEN** 作业正常结束，成功行数 = 10000，失败行数 = 0，并输出吞吐（行/秒）基线数据

#### Scenario: 脏行不中断作业
- **WHEN** 源数据中混入少量类型不兼容行
- **THEN** 该行计入失败统计并被跳过，其余行继续同步，作业不中断
