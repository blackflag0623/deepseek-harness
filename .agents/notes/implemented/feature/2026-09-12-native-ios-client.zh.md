# Agent Note: 原生 iOS 客户端

Status: implemented

[English](2026-09-12-native-ios-client.md) | 中文

## 问题

浏览器前端可以远程控制 dsh Host，但个人 iPhone 客户端需要原生导航、触控行为、安全区布局与高效增量更新，同时不能把 agent 运行时或仓库移到手机上。第二套移动端后端会复制 Session 权威来源，并让手机负责本就属于开发机器的基础设施。

## 决策

鲸鱼娘是位于 `apps/ios` 的原生 SwiftUI 应用。它只负责前端：dsh Web profile 仍是模型调用、工具、工作目录、Session 持久化与认证的唯一 Host。

App 直接消费现有 Typert Gateway wire（线路）操作。HTTP 承载 `session/list`、`session/create`、`session/prompt` 与 `session/cancel`，Gateway 已认证的 `/api/remote.stream` HTTP NDJSON 载体承载 `session/follow`。原生 HTTP 载体与浏览器 WebSocket 都从同一个 dispatcher 发出相同的 Gateway frame；但 HTTP 载体不存在时，iOS App 会显示 Host 升级指引，而不会进入已知会在目标 iPhone tunnel 路径上卡住的 WebSocket 重试循环。Session 选择属于本地导航，而打开 follow stream（跟随流）会执行现有冷读取和 Host promotion（提升）。App 不增加平行的 REST API 或移动端投影服务。

连接页面接受 Web 应用输出的已认证 URL。URLSession 使用一次性查询 token 换取现有签名浏览器 cookie，在持久保存 Host URL 前移除 token，并为 HTTP 与 WebSocket 流量复用 cookie。Production 构建要求 HTTPS。Tunnel 或反向代理终止 TLS，并把请求转发到 Web profile 的 loopback 监听器。

`ConversationProjection` 把初始 Session snapshot、更早的历史分页与后续事件折叠成面向 Turn（轮次）的移动端状态。人工消息与 assistant 文本渲染为气泡。长按会显示带有整条 Copy 和 Select Text 的系统上下文菜单；Select Text 会打开原生可选文本视图，以便用户复制精确范围。推理、工具参数、工具结果、流式状态、取消和失败留在所属 Turn 的可展开过程面板内。临时 assistant 分块会原位更新活跃 Turn，持久 assistant 事件则替换对应临时消息。

每个工作目录分组初始渲染最近更新的五个 Session。组内 disclosure（展开控件）显示或隐藏其余 Session，且不改变 Host 顺序，也不修改 Workspace 状态。

每个已完成的用户与 assistant 气泡都使用 MarkdownUI 的 GitHub 风格 parser（解析器）与 renderer（渲染器）。App 按消息身份与源内容缓存解析后的文档，为代码块提供自有的等宽字体表面，并让宽表格在气泡内横向滚动。整条复制与范围选择操作仍使用原始源文本。

前台拥有实时 follower。进入后台时，App 会取消 follower 并等待其静止，但不会取消 Agent；重新进入前台时，App 会打开新的 `session/follow` generation，并在权威 snapshot 到达前保留上一份 transcript。连接断开、超时与 POSIX connection abort 属于瞬态恢复状态：它们使用有上限的指数退避重试，并驱动带动画的非模态状态。认证、协议和业务失败会停止循环，并提供可操作的 Retry 或连接设置指引。

上次选中的 Session id 与清理后的 Host URL 会跨进程终止保留。强制退出不要求存在清理路径；操作系统关闭客户端传输，Host Agent 保持独立，下一个进程通过新的列表与 follow snapshot 恢复。

开发早期可观察性属于交付源码。`WhaleDiagnostics` 持有保护隐私的 App、生命周期、传输、Session 与交互 OSLog 分类；Debug 构建还会把恢复关键状态镜像到 stdout，供 `devicectl --console` 使用，并禁用自动锁屏。诊断记录 endpoint 名称、计数、generation 编号、错误 domain 与 code，但绝不记录 Host URL、cookie、Session id、工作目录或消息内容。

## 考虑过的替代方案

**在 WKWebView 中嵌入现有 Web 应用。** 这种方案可以复用浏览器渲染，但会保留移动浏览器布局和交互成本，原生导航模型也更弱，并让应用成为包装器而不是 iOS 前端。

**增加移动端专用 Host API。** 定制 REST 与 WebSocket 投影类似 Eva-Link 架构，但 dsh 已经提供带认证、冷历史与重连 snapshot 的类型化 unary 和 stream 操作。第二套 API 会复制授权、生命周期、事件解释与兼容工作。

**在 iOS 上运行 dsh。** 这种方案会把 Node、工具、源文件访问、凭据与进程执行移到受限设备上。它违背客户端的产品理由：开发机器仍是执行环境。

## 后果

手机可以浏览不同工作目录下的 Session、发送和停止工作，并跟随文本、推理与工具活动，而无需拥有项目文件或模型凭据。App 断开连接不会停止 Host Session。

原生投影有意只覆盖移动对话子集，不加载浏览器插件。新的 Session 事件类型会保持忽略，直到 App 为其提供原生展示；审批、文件、设置与插件贡献卡片等仅浏览器能力不可用。App 必须在同一仓库中跟进 Gateway 与 Session wire 变更，而现有 Host 协议仍是唯一传输权威。挂起 follower 意味着不承诺后台投递；重连 snapshot 是恢复权威。
