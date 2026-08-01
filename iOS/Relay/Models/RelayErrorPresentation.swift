import Foundation

enum RelayRecoveryAction: Equatable {
    case reconnect
    case editConnection
    case openDiagnostics
    case openSystemSettings

    var label: String {
        switch self {
        case .reconnect: return "重新连接"
        case .editConnection: return "检查连接信息"
        case .openDiagnostics: return "打开诊断中心"
        case .openSystemSettings: return "打开系统设置"
        }
    }
}

struct RelayErrorPresentation: Equatable {
    let title: String
    let message: String
    let technicalDetails: String
    let recoveryAction: RelayRecoveryAction?

    static func make(_ rawMessage: String) -> RelayErrorPresentation {
        let details = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = details.lowercased()

        if containsAny(normalized, ["通知权限", "notification permission", "未授予 relay 通知权限"]) {
            return RelayErrorPresentation(
                title: "通知未开启",
                message: "请在系统设置中允许 Relay 发送通知。",
                technicalDetails: details,
                recoveryAction: .openSystemSettings
            )
        }

        if containsAny(normalized, ["401", "unauthorized", "authentication", "pairing token", "配对令牌", "鉴权", "身份验证"]) {
            return RelayErrorPresentation(
                title: "连接信息无效",
                message: "Windows 拒绝了这次连接。请检查连接地址和配对令牌。",
                technicalDetails: details,
                recoveryAction: .editConnection
            )
        }

        if containsAny(normalized, ["429", "rate limit", "rate_limit", "quota", "额度", "请求过多"]) {
            return RelayErrorPresentation(
                title: "服务额度或频率受限",
                message: "上游服务暂时拒绝了请求。请检查 API 额度或稍后再试；未确认的消息不会自动标记为已处理。",
                technicalDetails: details,
                recoveryAction: .openDiagnostics
            )
        }

        if containsAny(normalized, ["连接已恢复", "connection has been restored"]) {
            return RelayErrorPresentation(
                title: "连接已经恢复",
                message: details,
                technicalDetails: details,
                recoveryAction: nil
            )
        }

        if containsAny(normalized, ["连接仍保持", "connection is still active"]) {
            return RelayErrorPresentation(
                title: "请求等待超时",
                message: details,
                technicalDetails: details,
                recoveryAction: nil
            )
        }

        if containsAny(normalized, connectionMarkers) {
            return RelayErrorPresentation(
                title: "与 Windows 的连接中断",
                message: "Relay 会保留尚未确认的内容。请确认 Tailscale 和 Relay Desktop 在线，然后重新连接。",
                technicalDetails: details,
                recoveryAction: .reconnect
            )
        }

        if containsAny(normalized, fileMarkers) {
            return RelayErrorPresentation(
                title: "文件处理失败",
                message: fileMessage(details),
                technicalDetails: details,
                recoveryAction: nil
            )
        }

        if containsHanCharacter(details) {
            return RelayErrorPresentation(
                title: "暂时无法完成",
                message: details,
                technicalDetails: details,
                recoveryAction: nil
            )
        }

        return RelayErrorPresentation(
            title: "操作未完成",
            message: "Relay 未能完成这次操作。可以打开诊断中心查看连接和服务状态。",
            technicalDetails: details,
            recoveryAction: .openDiagnostics
        )
    }

    static func shouldPresentNonfatal(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return !containsAny(normalized, [
            "ignored one unsupported bridge message",
            "ignored one invalid bridge message"
        ])
    }

    private static let connectionMarkers = [
        "disconnected",
        "connection timed out",
        "failed to connect",
        "network connection was lost",
        "not connected",
        "windows host is disconnected",
        "fetch failed",
        "尚未连接到 windows",
        "连接已断开",
        "正在重新连接",
        "正在重连",
        "没有确认收到消息",
        "长时间没有确认请求",
        "bridge 正在关闭"
    ]

    private static let fileMarkers = [
        "file",
        "upload",
        "download",
        "photo",
        "image",
        "ipa",
        "文件",
        "上传",
        "下载",
        "照片",
        "图片"
    ]

    private static func containsAny(_ value: String, _ markers: [String]) -> Bool {
        markers.contains { value.contains($0) }
    }

    private static func containsHanCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    private static func localizedMessage(_ value: String, fallback: String) -> String {
        containsHanCharacter(value) ? value : fallback
    }

    private static func fileMessage(_ details: String) -> String {
        if containsHanCharacter(details) { return details }
        let normalized = details.lowercased()
        let summary: String
        if normalized.contains("outside the configured workspace") {
            summary = "该文件不在当前工作区内，且当前对话没有引用这个路径。"
        } else if normalized.contains("not found") || normalized.contains("enoent") {
            summary = "Windows 上已找不到这个文件。"
        } else if normalized.contains("50 mb") || normalized.contains("25 mb") {
            summary = "文件超过 Relay 当前允许的传输大小。"
        } else {
            summary = "Relay 未能完成这次文件操作，请重新选择或稍后再试。"
        }
        return "\(summary)\n\n原始错误：\(details)"
    }
}
