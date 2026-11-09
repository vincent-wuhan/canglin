# desktop-shell

## ADDED Requirements

### Requirement: 三栏桌面布局
应用 SHALL 在鸿蒙桌面端（ArkUI-Cangjie）呈现三栏布局：左侧连接/对象栏、中部编辑区、右侧结果区，三栏 SHALL 可见且不重叠。

#### Scenario: 三栏渲染
- **WHEN** 应用启动
- **THEN** 三栏布局渲染完成，各栏显示占位内容

### Requirement: webview 内嵌 Monaco 编辑器
中部编辑区 SHALL 通过 webview 加载本地打包的 Monaco Editor（无网络依赖），SHALL 支持 SQL 语法高亮与文本编辑。

#### Scenario: Monaco 离线加载与编辑
- **WHEN** 应用启动后进入编辑区输入 SQL 文本
- **THEN** Monaco 正常渲染，SQL 关键字高亮，文本可编辑修改

#### Scenario: webview 与仓颉层通信
- **WHEN** 在 Monaco 中触发"执行"动作（如按钮或命令）
- **THEN** 编辑区文本经 webview 桥接传回仓颉侧并被接收（内容一致即可，不要求真实执行）
