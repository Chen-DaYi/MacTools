import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

struct RunLinkExecutionFeedback: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case success
        case failure
    }

    let tone: Tone
    let title: String
    let message: String
}

@MainActor
protocol RunLinkFeedbackPresenting: AnyObject {
    func present(_ feedback: RunLinkExecutionFeedback)
}

@MainActor
final class SystemRunLinkFeedbackPresenter: RunLinkFeedbackPresenting {
    static let panelIdentifier = NSUserInterfaceItemIdentifier("mactools.run-link.feedback")

    private let dismissDelay: Duration
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    init(dismissDelay: Duration = .seconds(4)) {
        self.dismissDelay = dismissDelay
    }

    func present(_ feedback: RunLinkExecutionFeedback) {
        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: 360, height: 86)
        let visibleFrame = screen.visibleFrame
        let frame = NSRect(
            x: visibleFrame.maxX - size.width - 18,
            y: visibleFrame.maxY - size.height - 18,
            width: size.width,
            height: size.height
        )
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
            panel.setFrame(frame, display: true)
        } else {
            panel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            panel.identifier = Self.panelIdentifier
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .statusBar
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .transient,
                .ignoresCycle,
            ]
            self.panel = panel
        }
        panel.setAccessibilityLabel("\(feedback.title)，\(feedback.message)")
        panel.contentView = NSHostingView(
            rootView: RunLinkFeedbackView(feedback: feedback)
        )
        panel.orderFrontRegardless()

        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self, dismissDelay] in
            try? await Task.sleep(for: dismissDelay)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    isolated deinit {
        dismissTask?.cancel()
        panel?.close()
    }
}

private struct RunLinkFeedbackView: View {
    let feedback: RunLinkExecutionFeedback
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: feedback.tone == .success
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(feedback.tone == .success ? Color.green : Color.red)

            VStack(alignment: .leading, spacing: 4) {
                Text(feedback.title)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(feedback.message)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(width: 360, height: 86)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    reduceTransparency
                        ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                        : AnyShapeStyle(.regularMaterial)
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(feedback.title)，\(feedback.message)")
    }
}

@MainActor
final class AppActionConfirmationService: ActionConfirmationRequesting {
    private let windowProvider: @MainActor () -> NSWindow?

    init(windowProvider: @escaping @MainActor () -> NSWindow?) {
        self.windowProvider = windowProvider
    }

    func confirm(_ request: ActionConfirmationRequest) async -> Bool {
        guard let window = windowProvider() else {
            return false
        }
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.confirmation.title
        alert.informativeText = request.confirmation.message
        alert.addButton(withTitle: request.confirmation.confirmButtonTitle)
        alert.addButton(withTitle: "取消")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }
}

@MainActor
final class RunLinkExecutionCoordinator {
    private let registry: ActionRegistry
    private let executor: ActionExecutor
    private let runLinkService: ActionRunLinkService
    private let confirmationService: any ActionConfirmationRequesting
    private let feedbackPresenter: any RunLinkFeedbackPresenting

    init(
        registry: ActionRegistry,
        executor: ActionExecutor,
        runLinkService: ActionRunLinkService,
        confirmationService: any ActionConfirmationRequesting,
        feedbackPresenter: any RunLinkFeedbackPresenting
    ) {
        self.registry = registry
        self.executor = executor
        self.runLinkService = runLinkService
        self.confirmationService = confirmationService
        self.feedbackPresenter = feedbackPresenter
    }

    func execute(_ request: ActionRunLinkRequest) async {
        let reference: ActionReference
        switch runLinkService.resolve(request) {
        case let .success(value):
            reference = value
        case let .failure(error):
            feedbackPresenter.present(
                RunLinkExecutionFeedback(
                    tone: .failure,
                    title: "运行链接不可用",
                    message: message(for: error)
                )
            )
            return
        }

        guard case let .success(action) = registry.registeredAction(for: reference) else {
            feedbackPresenter.present(
                RunLinkExecutionFeedback(
                    tone: .failure,
                    title: "运行链接不可用",
                    message: "操作提供方当前不可用。"
                )
            )
            return
        }
        let mode: ActionExecutionMode = action.definition.capabilities
            .contains(.foregroundInteractive) ? .foreground : .background
        let outcome = await executor.execute(
            ActionInvocation(reference: reference, source: .runLink, mode: mode),
            confirmationService: confirmationService
        )
        feedbackPresenter.present(feedback(for: outcome))
    }

    private func feedback(for outcome: ActionExecutionOutcome) -> RunLinkExecutionFeedback {
        switch outcome {
        case .completed(.succeeded):
            return RunLinkExecutionFeedback(
                tone: .success,
                title: "操作已完成",
                message: "运行链接执行成功。"
            )
        case .completed(.failed):
            return RunLinkExecutionFeedback(
                tone: .failure,
                title: "操作失败",
                message: "操作未能完成。"
            )
        case .completed(.cancelled):
            return RunLinkExecutionFeedback(
                tone: .failure,
                title: "操作已取消",
                message: "运行链接未完成。"
            )
        case let .rejected(rejection):
            return RunLinkExecutionFeedback(
                tone: .failure,
                title: "无法执行操作",
                message: message(for: rejection)
            )
        }
    }

    private func message(for error: ActionRunLinkResolutionError) -> String {
        switch error {
        case .unknownAction:
            "找不到对应操作；请检查插件是否已安装并启用。"
        case .unavailablePreset:
            "运行链接预设不存在或已删除。"
        case .parameterizedDirectAction:
            "此操作需要使用已保存的运行链接预设。"
        case .externalInvocationUnavailable:
            "此操作不允许从外部调用。"
        case .sensitiveParametersUnsupported:
            "包含敏感参数的预设不能通过运行链接调用。"
        }
    }

    private func message(for rejection: ActionExecutionRejection) -> String {
        switch rejection {
        case .unknownAction, .providerChanged:
            "操作提供方已发生变化，请重试。"
        case .invalidParameters:
            "运行链接参数无效。"
        case .providerFailure:
            "操作提供方未能开始执行。"
        case let .unavailable(reason):
            reason ?? "操作当前不可用。"
        case .backgroundExecutionUnsupported, .foregroundExecutionUnsupported:
            "操作不支持当前执行方式。"
        case .externalInvocationUnavailable:
            "此操作不允许从外部调用。"
        case .confirmationUnavailable:
            "此操作需要确认，但无法显示确认界面。"
        case .confirmationDenied:
            "用户取消了操作。"
        case .confirmationTimedOut:
            "确认已超时。"
        case .executionTimedOut:
            "操作执行超时。"
        }
    }
}
