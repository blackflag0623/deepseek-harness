# iOS 版鲸鱼娘

[English](README.md) | 中文

鲸鱼娘是运行在开发机器上的 dsh Web Host 的私有 SwiftUI 前端。iPhone 只保存展示状态和 Host 签发的浏览器 cookie；模型请求、工具、源文件、Session（会话）与持久历史都留在 Host。

App 图标使用为这个私人客户端生成并选定的蓝色鲸鱼帽吉祥物图稿。

## 使用

在 Xcode 中打开 `鲸鱼娘.xcodeproj`，并在 iOS 17 或更高版本的 iPhone 上运行 `WhaleGirl` scheme。通过 HTTPS tunnel（隧道）把请求转发至 dsh Web Host 的 loopback（回环）监听器，再把 `dsh web` 打印的完整 URL（包含一次性 `token` 查询参数）粘贴进连接页面。App 使用该 token 换取普通的、绑定 authority 的 dsh 浏览器 cookie，且只保存清理后的 Host URL。

侧边栏按 Host `cwd` 对所有可见 Session 分组，每组默认显示最近更新的五项，并可按需展开更早的条目。选择 Session 后，App 会打开其当前历史、向前分页加载更早消息，并跟随后续持久事件与实时 assistant（助手）流帧。输入框发送排队文本提示词，也可以取消正在运行的轮次。每个用户与 assistant 气泡都渲染 GitHub 风格 Markdown，包括可横向滚动的表格与带样式的代码块。推理和工具调用在可展开的执行面板内原位更新。长按消息气泡会打开标准的 Copy 和 Select Text 操作；Select Text 会打开原生可选择视图，以便精确选择并复制部分文字。

## 架构

App 直接调用现有 Typert Gateway，不增加移动端专用业务后端。Unary（单次）操作使用已认证的 `/api/<namespace>/<method>` envelope（信封），每个实时 Session 通过 Gateway 的 `/api/remote.stream` HTTP NDJSON 载体打开 `session/follow`。不具备该载体的 Host 会收到升级指引，而不会进入不可靠的 WebSocket 重试循环。`ConversationProjection` 从 Session 事件和临时 assistant 帧派生移动端时间线；重连时，下一份权威 snapshot（快照）会替换时间线。

App 在所有构建中都接受 HTTPS。Debug 构建还接受用于本地开发的 HTTP，而应用传输策略只允许本地网络。远程部署仍负责 TLS 终止，并把请求转发至仅监听 loopback 的 dsh Web 服务。

## iOS 生命周期与恢复

前台拥有实时 `session/follow` socket。进入后台（包括锁屏）时，App 会取消并等待该 follower（跟随器）结束，但不会发送 `session/cancel`；Host Agent 及其持久 Session 会独立继续运行。重新进入 active（活跃）状态后，App 会立即打开新的 follower，其初始 snapshot 在增量事件恢复前替换可见尾部。恢复期间，当前对话仍保持可见。

强制退出时，App 不一定能获得清理回调。操作系统会关闭其传输连接，而 Host 会继续运行。下次启动时，持久的 dsh 浏览器 cookie 会重新连接，Session 列表会刷新；若上次选中的 Session 仍存在，App 会重新打开它。

Connection abort（连接中止）、超时或网络断开等传输失败属于自动恢复状态。它们只显示带动画的重连提示，不弹模态错误。认证、协议与 Host 业务失败会停止自动重试，并显示带 Retry 或连接设置指引的可操作消息。

开发早期诊断会提交进仓库。结构化 OSLog 分类覆盖 App、生命周期、传输、Session 状态与交互里程碑，但不记录 Host URL、cookie、Session id、路径或消息内容。Debug 构建会把恢复关键事件镜像到已连接的设备控制台，并禁用自动锁屏，使真机验收过程持续可观察。

## 当前范围

- 浏览、搜索、创建和打开横跨 Host 工作目录的 Session。
- 发送文本提示词、停止活跃工作，并在不停止 Host Session 的情况下重新连接。
- 展示 Markdown 用户与 assistant 气泡、流式文本、推理、工具参数、工具结果和轮次结果。

Workspace 编辑、文件传输、审批、语音、通知、Watch 支持与 App Store 分发不属于此客户端。

## 开发

无需代码签名即可构建 App：

```sh
xcodebuild -project 'apps/ios/鲸鱼娘.xcodeproj' -scheme WhaleGirl -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

在已安装的模拟器上运行投影测试：

```sh
xcodebuild -project 'apps/ios/鲸鱼娘.xcodeproj' -scheme WhaleGirl -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO test
```

[原生 iOS 客户端 Agent Note](../../.agents/notes/implemented/feature/2026-09-12-native-ios-client.zh.md)记录了产品边界和被否决的替代方案。
