import XCTest
@testable import Relay

final class RelayErrorPresentationTests: XCTestCase {
    func testUnauthorizedConnectionOffersConnectionEditor() {
        let presentation = RelayErrorPresentation.make("HTTP 401 Unauthorized")

        XCTAssertEqual(presentation.title, "连接信息无效")
        XCTAssertEqual(presentation.recoveryAction, .editConnection)
        XCTAssertEqual(presentation.recoveryAction?.label, "检查连接信息")
        XCTAssertEqual(presentation.technicalDetails, "HTTP 401 Unauthorized")
    }

    func testRateLimitExplainsQuotaWithoutDumpingRawResponse() {
        let raw = "429 rate_limit_exceeded: quota exhausted"
        let presentation = RelayErrorPresentation.make(raw)

        XCTAssertEqual(presentation.title, "服务额度或频率受限")
        XCTAssertEqual(presentation.recoveryAction, .openDiagnostics)
        XCTAssertFalse(presentation.message.contains("rate_limit_exceeded"))
        XCTAssertEqual(presentation.technicalDetails, raw)
    }

    func testDisconnectedConnectionOffersReconnectAndProtectsMessageExpectation() {
        let presentation = RelayErrorPresentation.make("The Windows host is disconnected.")

        XCTAssertEqual(presentation.title, "与 Windows 的连接中断")
        XCTAssertEqual(presentation.recoveryAction, .reconnect)
        XCTAssertTrue(presentation.message.contains("保留"))
    }

    func testRecoveredConnectionDoesNotOfferRedundantReconnect() {
        let raw = "Windows 连接已恢复，请稍后重试；输入内容仍保留在输入框中。"
        let presentation = RelayErrorPresentation.make(raw)

        XCTAssertEqual(presentation.title, "连接已经恢复")
        XCTAssertEqual(presentation.message, raw)
        XCTAssertNil(presentation.recoveryAction)
    }

    func testRequestTimeoutThatKeepsConnectionDoesNotOfferReconnect() {
        let raw = "Windows 长时间没有完成请求，但连接仍保持。"
        let presentation = RelayErrorPresentation.make(raw)

        XCTAssertEqual(presentation.title, "请求等待超时")
        XCTAssertNil(presentation.recoveryAction)
    }

    func testEnglishFileFailureUsesLocalizedSummary() {
        let presentation = RelayErrorPresentation.make("Download failed: invalid file data")

        XCTAssertEqual(presentation.title, "文件处理失败")
        XCTAssertTrue(presentation.message.contains("文件操作"))
        XCTAssertTrue(presentation.message.contains("Download failed"))
        XCTAssertEqual(presentation.technicalDetails, "Download failed: invalid file data")
    }

    func testOutsideWorkspaceErrorKeepsTheOriginalReasonVisible() {
        let raw = "That file is outside the configured workspace and was not referenced by the current conversation."
        let presentation = RelayErrorPresentation.make(raw)

        XCTAssertTrue(presentation.message.contains("当前对话"))
        XCTAssertTrue(presentation.message.contains(raw))
    }

    func testChineseBusinessGuidanceIsPreserved() {
        let raw = "请先发送或清空当前输入框，再编辑排队消息。"
        let presentation = RelayErrorPresentation.make(raw)

        XCTAssertEqual(presentation.title, "暂时无法完成")
        XCTAssertEqual(presentation.message, raw)
        XCTAssertNil(presentation.recoveryAction)
    }

    func testUnknownTechnicalErrorRoutesToDiagnostics() {
        let presentation = RelayErrorPresentation.make("Unexpected upstream response")

        XCTAssertEqual(presentation.title, "操作未完成")
        XCTAssertEqual(presentation.recoveryAction, .openDiagnostics)
        XCTAssertFalse(presentation.message.contains("Unexpected upstream response"))
    }

    func testUnsupportedBridgeMessagesStayOutOfUserAlerts() {
        XCTAssertFalse(RelayErrorPresentation.shouldPresentNonfatal("Ignored one unsupported Bridge message."))
        XCTAssertFalse(RelayErrorPresentation.shouldPresentNonfatal("Ignored one invalid Bridge message: bad payload"))
        XCTAssertTrue(RelayErrorPresentation.shouldPresentNonfatal("Relay Bridge 正在关闭。"))
    }
}
