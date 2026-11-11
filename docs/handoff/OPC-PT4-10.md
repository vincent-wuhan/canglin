# OPC 小队交接包：PT4-PT10（canglin POC 实施）

> 面向：云上奔悦小队（multica benyue workspace）执行角色
> 委派方：本地 controller（comet 流程 poc-technical-validation change）
> 更新：2026-11-10

## 项目一句话

canglin（仓廪）= 仓颉版多源数据库客户端（对标 Navicat，信创方向），DataX 插件式内核架构，远期演进智能数据网关。当前处于 POC 技术验证阶段。

## 仓库与分支

- 主仓：https://gitcode.com/glorius/canglin（公开）
- 镜像：https://github.com/vincent-wuhan/canglin（公开）
- 工作分支：`poc-technical-validation`（从该分支拉，往该分支推）
- 事实源：`openspec/changes/poc-technical-validation/`（proposal/specs/tasks）+ `docs/superpowers/`（design/plan）

## 环境搭建（实施前必读）

1. **Cangjie SDK：基线已升级为 1.1.x STS（2026-11-11 决定）**——从 https://cangjie-lang.cn/download 选 1.1.x STS 正式版（不要用 beta.25）。driver-pg 的限定依赖语法与 stdx.net.tls 依赖 1.1。stdx 从 gitcode `Cangjie/cangjie_stdx` releases 获取（mac/linux 各平台包均有）。构建配方必须脚本化进 env/（cangjie-env.sh 不得硬编码个人 $HOME 路径），保证任意机器可复现。每条 shell 命令都要带 source（shell 状态不跨命令保留）
2. **Docker 测试矩阵**（PT7-PT10 需要）：`cd env && docker compose up -d`——MySQL8:3306 / PG16:5432 / openGauss:5433，root 密码 canglin123（openGauss: Canglin@123），MySQL 已含 1 万行 src_users 源表。**改过 init SQL 后重置必须 `docker compose down -v`**（匿名卷复用会静默跳过 init）
3. **镜像拉取**：直连 Docker Hub 可能 EOF，可走 daocloud 镜像（mysql/pg）；opengauss 命名空间 daocloud 不代理，可用 1ms.run，拉完 tag 回官方名。**opengauss:7.0.0-RC3.B025 arm64 是坏镜像**（缺 libopenblas），用 7.0.0-RC1

## 仓颉 1.0.5 校准坑（本地三个任务真金白银踩出来的，别再踩）

| # | 坑 | 规避方式 |
|---|---|---|
| 1 | `Bool` 是仓颉关键字 | 枚举构造器/模式匹配写反引号：`` Column.`Bool`(true) ``、`` case `Bool`(v) `` |
| 2 | `@Derive` 对反引号构造器名生成非法函数名（1.0.5 工具链 bug，Equatable/ToString 都炸） | 手写 `extend X <: Equatable<X>` / `extend X <: ToString`（参考 kernel/src/record/column.cj） |
| 3 | std.sync 没有 MultiCondSync；Monitor 已弃用 | 用 `MultiConditionMonitor`：持锁 `newCondition()` 得 ConditionID，`wait(cid)/notifyAll(cid)`，**无 notifyOne** |
| 4 | `cjpm test` 假成功：测试文件不被发现时 TOTAL:0 且退出码 0 | 验收必须断言 `PASSED > 0`，不能只看退出码 |
| 5 | spawn 捕获可变变量的 lambda 不能逃逸（编译报错） | 跨协程标志位用引用类型字段承载（`class Flag { var v: Bool = false }`） |
| 6 | cjpm 要求 src/ 根目录至少一个 .cj 文件 | 否则子目录全不扫描（kernel/src/kernel.cj 占位就是为此） |

## 已完成的地基（直接建在它们上面，不要重写）

- `kernel/src/record/`：Column 七类枚举（Long/Double/Str/Bytes/Bool/Date/Null，手写 Equatable+ToString）+ Record（防御性拷贝，get/size）
- `kernel/src/channel/`：BoundedChannel（MultiConditionMonitor 双条件变量，背压/关闭EOF/不丢不重/close 幂等，容量默认 1024）
- **术语契约（极易弄反）**：SPI **Reader = 生产方**（调 `channel.send(...)`，完成后 `channel.close()`）；**Writer = 消费方**（循环 `channel.recv()` 到 None 退出）
- 测试现状：kernel 7/7 全绿；`mockRecord`/`Flag` 助手在 `kernel/src/test/channel_test.cj`（复用时提公共）

## 任务清单（7 个 issue 对应关系）

任务书全文：`docs/superpowers/plans/2026-11-09-poc-technical-validation.md`（Task 4-10 节，含接口草图与测试语义）；spec 验收场景：`openspec/changes/poc-technical-validation/specs/{sync-kernel,driver-connectivity}/spec.md`

| Issue | 内容 | 依赖 | Docker |
|---|---|---|---|
| PT4 | Reader/Writer SPI + 内存假实现（TDD：单侧可替换） | 无 | 否 |
| PT5 | JobRunner 双协程流水线 + 统计（ok/dirty/耗时） | PT4 | 否 |
| PT6 | driver-api（DbDriver/Connection/RowSet/DbError 四类） | 无 | 否 |
| PT7 | MySQL 适配器（mysqlclient4cj 引入校准 + L2 集成测试） | PT6 | 是 |
| PT8 | PG/openGauss 适配器（opengauss-driver，双端点同测试函数） | PT6,PT7 | 是 |
| PT9 | 错误四分类 + close 幂等测试（两适配器） | PT7,PT8 | 是 |
| PT10 | CLI 万行同步（MySQL→PG，吞吐基线 + 脏行变体） | PT5,PT9 | 是 |

串行链：PT4→PT5、PT6→PT7→PT8→PT9→PT10；PT4-PT6 可与 PT6-PT7 并行起点。**openGauss 容器内需先建业务用户**（omm 禁止远程登录，pg_hba 已放行 md5）——PT8 第一步。

## 验收口径（每个任务）

1. TDD：先看到失败测试，再实现（报告附红→绿 Summary 行）
2. `cjpm test` 全绿且 **PASSED > 0**
3. spec 场景逐条对照（openspec delta spec 是验收事实源）
4. 一个任务一个 commit（仅本任务相关文件），message 风格见 git log
5. L2 集成测试在 Docker 不可用时显式跳过并在报告声明
6. 社区库（mysqlclient4cj/opengauss-driver）接入方式与版本记入 `env/driver-notes.md`

## 回报协议

每完成一个 PT：推送 `poc-technical-validation` 分支到双远端（gitcode + github 都要推），issue 评论附：commit SHA、cjpm test Summary（数字须实跑，不得估算）、校准新发现（如有）、concerns。本地 controller 会对每个 commit 做规格符合性 + 质量两阶段审查，审查意见回 issue 评论。

**提交规范（2026-11-11 起）**：这是对外公开仓，commit message 一律不得携带 AI Co-Authored-By 署名或任何模型标识；单一 commit 必须可独立构建（依赖它的提交不得排在其前）。

## 明确不做（YAGNI）

作业分片/限速/断点续传、多生产多消费优化、金仓/达梦、UI、智能层。发现 spec 缺验收场景：提出来回写 delta spec，不要自行加需求。
