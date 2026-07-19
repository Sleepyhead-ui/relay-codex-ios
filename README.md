# Relay

Relay 是一个面向 iOS 16 的非官方 Codex 远程客户端。它通过 Windows 上的本地 Bridge 与 Codex App Server 通信，不在手机或 GitHub 中保存 OpenAI 登录凭据。

> Relay 与 OpenAI 无关联，不使用 ChatGPT 或 Codex 的名称、图标作为应用品牌。当前版本是可安装 MVP，协议固定到 `@openai/codex 0.144.5`。

## 已实现

- iOS 16 SwiftUI 客户端，支持浅色和深色模式
- ChatGPT 风格的克制聊天布局、侧栏和底部输入器
- 二维码深链配对与 Keychain Token 存储
- 新建、列出和恢复本机 Codex 会话
- 流式 Agent 消息、Reasoning、命令输出、文件变更和工具状态
- 命令、文件修改和额外权限审批
- 停止正在运行的 Turn
- Tailscale 网络和 Bearer Token 双层保护
- GitHub Actions 自动生成 TrollStore 可安装的未签名 IPA
- 结构化处理过程：思考摘要、计划、命令、文件修改、工具结果和处理时间
- 原生风格 Markdown：标题、列表、引用、代码块、表格、行内链接和代码复制
- 从 Codex 模型目录读取模型及其可用推理强度
- 上下文 Token 占用、手动压缩和压缩事件展示
- 打开线程自动定位到最新一轮，浏览历史时显示“跳到最新”按钮
- Windows 增强桌面同步：手机任务完成后无焦点刷新桌面渲染层并重新打开目标线程
- 输入框 `+` 菜单可从照片图库或文件 App 选择多个附件，图片和普通文件会以原生 Codex 输入类型发送
- 下载对话中的文件改动、生成图片和本地文件链接，并通过 iOS 分享菜单保存
- 只读、工作区写入、完全访问三档工作区权限
- 顶部齿轮按钮可随时进入设置并切换工作区权限
- 短思考只显示最新一条，完整进展逐条保留；Markdown 标记不会以原始符号泄漏到界面
- 多条命令默认合并为一个紧凑执行组，展开后可逐项查看状态和技术详情
- 执行组按实际时间线穿插在进展之间，任务结束后自动折叠为“已处理 · 用时”
- iOS 16 原生相册与文件选择器会先安全导入本地副本，再显示上传进度并发送给 Codex
- 上下文占用只保留在输入框内：80% 起橙色预警，90% 起显示一键压缩提醒
- 底部 Composer 去除整条材质背景，输入框以独立悬浮层呈现；思考加载状态与首行文字对齐
- 自启动安装在任务计划不可用时自动回退到当前用户登录启动项
- 最近 8 个对话使用内存快照即时切换；前台重连保留当前画面并在后台静默校准
- 侧栏任务索引持久化到本机，启动时即时显示并通过状态数据库在后台快速刷新
- 多个线程可以并行运行，任务和折叠项目会显示独立的运行状态
- 运行中支持 Codex 原生 `turn/steer` 引导，也可将后续消息排队到下一轮自动发送
- 发送过程显示确认状态；断线或超时会明确提示、恢复输入并自动重连
- 连接稳定后才重置指数退避，单条业务错误不会触发一秒一次的重连风暴
- 结构化执行计划显示在输入框上方，以加载、勾选和待办状态实时更新
- 最多八行的动态输入框，发送后自动收起键盘

## 架构

```text
iPhone / Relay
    │  Bearer Token + Tailscale 加密网络
    ▼
Windows Relay Bridge (WebSocket)
    │  JSON-RPC over stdio
    ▼
Codex App Server 0.144.5
    │
    └─ Windows 文件、终端、MCP、技能和本机登录
```

Bridge 使用稳定的 stdio 传输连接 Codex，避免直接把仍属实验性质的 Codex WebSocket listener 暴露到网络。手机断开后 Bridge 和 Codex 进程仍可继续工作；重新连接后可以读取线程历史和仍待处理的审批。

## 1. 准备 Windows

需要：

- Windows 10/11
- Node.js 20 或更新版本
- 已登录的 Codex。可先在 PowerShell 执行 `codex login`
- Windows 与 iPhone 都安装并登录同一个 Tailscale 网络

在 `Bridge` 目录运行：

```powershell
.\Start-Relay.ps1 -WorkingDirectory "C:\path\to\your-project" -DesktopSync
```

`-DesktopSync` 是可选的桌面刷新模式。Bridge 会让 Windows Codex 以仅监听 `127.0.0.1:9223` 的调试通道启动；手机完成一轮任务后，Bridge 先无焦点刷新桌面渲染层，再通过官方 `codex://threads/<id>` 打开同一线程。若 Codex 已经在未启用调试通道的状态下运行，本次会暂时退回基础深链；完全退出 Codex 后再从手机发送一次消息即可自动重新启动增强模式。

调试端口只绑定本机回环地址，不应改为 Tailscale 地址或公网地址。设置页会显示“增强刷新”“基础深链”或“等待检测”，便于确认实际同步模式。

脚本会：

1. 首次启动时安装固定版本的本地 Codex 和 Bridge 依赖；后续启动可离线复用。
2. 自动使用 Tailscale IPv4 地址监听。
3. 在首次启动时生成 `~\.relay\token`。
4. 输出配对二维码、手机连接地址和手动 Token。

如果没有 Tailscale，Bridge 默认只监听 `127.0.0.1`，手机无法远程连接。

让 Bridge 登录后自动运行：

```powershell
.\Install-Autostart.ps1 -WorkingDirectory "C:\path\to\your-project" -DesktopSync
```

该命令会创建当前用户的 Windows 计划任务。执行前可先检查脚本内容。

## 2. 使用 GitHub Actions 构建 IPA

把 `Relay` 目录提交到 GitHub 仓库，然后打开 **Actions → Build Relay → Run workflow**。

构建完成后：

1. 打开该次 Workflow Run。
2. 下载 `Relay-unsigned-IPA` Artifact。
3. 解压得到 `Relay.ipa`。
4. 通过 TrollStore 安装。

推送 `v0.1.0` 这类 Tag 时，Workflow 还会自动创建 GitHub Release 并附加 IPA。

公开仓库通常不消耗私有仓库的 macOS 免费额度；私有仓库的 macOS Runner 会按 GitHub 账户额度计费或扣减分钟数。

## 3. 配对

1. 保持 Windows 上 `Start-Relay.ps1` 正在运行。
2. 用 iPhone 系统相机扫描 PowerShell 中的二维码。
3. 选择用 Relay 打开。
4. 检查 Tailscale 地址、电脑名称和默认项目目录。
5. 点击 **Connect**。

也可以手动输入：

- WebSocket address：例如 `ws://100.64.1.2:8765`
- Pairing token：Bridge 终端显示的 Token

## 安全约束

- 不要把 Bridge 端口映射到公网，也不要直接绑定公网 IP。
- `ws://` 只用于 Tailscale/WireGuard 已加密隧道内；公网入口必须另行配置 `wss://` 和反向代理。
- 不要提交 `~\.relay\token`、Codex 的 `auth.json` 或任何 OpenAI API Key。
- 默认使用 `workspace-write` 与 `on-request` 审批；可在设置中切换只读或完全访问。完全访问会显著扩大 Codex 能操作的范围。
- iOS App 开启了 ATS 非 TLS 连接，因为 Tailscale 内使用 `ws://`；离开可信 VPN 时不要使用该配置。
- Windows 必须保持唤醒、联网且用户会话可运行 Bridge。

## 当前限制

- iOS 被系统挂起后 WebSocket 不会持续保活。Windows 任务仍继续，重新打开 Relay 后会恢复历史；第一版没有 APNs 推送。
- 可以恢复本机保存的 Codex 线程，但不保证接管桌面 App 中正在输出的同一个活动 Turn。
- Git diff 专用高亮视图、语音和多主机切换留到后续版本。
- 单个上传或下载文件上限为 50 MB；下载仅允许当前工作区和 Relay 上传目录中的文件。
- Codex App Server 会演进。升级 `@openai/codex` 前，应重新生成 schema 并运行兼容测试。

## 本地开发

Bridge：

```powershell
cd Bridge
npm ci
npm test
npm start
```

iOS 工程由 XcodeGen 生成：

```bash
cd iOS
brew install xcodegen
swift Tools/GenerateAppIcons.swift
xcodegen generate
open Relay.xcodeproj
```

## 参考

- [Codex App Server](https://learn.chatgpt.com/docs/app-server)
- [Codex Remote connections](https://learn.chatgpt.com/docs/remote-connections)
- [Codex SDK](https://learn.chatgpt.com/docs/codex-sdk)
