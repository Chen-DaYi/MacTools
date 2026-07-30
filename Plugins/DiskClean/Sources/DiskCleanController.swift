import Combine
import Foundation
import MacToolsPluginKit

enum DiskCleanControllerPhase: Equatable, Sendable {
    case idle
    case scanning
    case scanned
    /// 永久删除的第二步（设计 §8.4）。计划已铸造并冻结，等待用户确认。
    case confirming
    case cleaning
    case completed
}

/// 过期门的时间来源（设计 §4.4 的可注入 Clock）。
///
/// 过期必须是**时间驱动**的：门限到点就要把按钮变灰，而不是等用户下次点击才发现。
/// 因此除了"现在几点"还需要"睡到某个时刻"，测试才能在不真等 300 秒的前提下驱动这次转换。
/// 确认窗口（§8.4）复用同一时钟。
protocol DiskCleanClock: Sendable {
    var now: Date { get }
    func sleep(until deadline: Date) async throws
}

struct DiskCleanSystemClock: DiskCleanClock {
    var now: Date { Date() }

    func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { return }
        // 上限只是防御性钳制：过期窗口是 300 秒，不可能接近溢出。
        let nanoseconds = min(interval, 86_400) * 1_000_000_000
        try await Task.sleep(nanoseconds: UInt64(nanoseconds))
    }
}

struct DiskCleanControllerSnapshot: Equatable, Sendable {
    let phase: DiskCleanControllerPhase
    /// 当前扫描范围。规则段是勾选的分组，开发产物段是配置的扫描根，安装包段无参数。
    let scope: DiskCleanScanScope
    let scanResult: DiskCleanScanResult?
    let executionResult: DiskCleanExecutionResult?
    /// 选择的扫描范围与结果不一致。
    let isResultStale: Bool
    /// 过期门已到（设计 §4.4）。误操作防护，不是 TOCTOU 防护。
    let isResultExpired: Bool
    let errorMessage: String?
    let scanLogEntries: [DiskCleanScanLogEntry]
    /// 当前删除方式。冻结进计划的是铸造时刻的值，改这里会作废待确认计划。
    let removalMode: DiskCleanRemovalMode
    /// 待确认计划的冻结摘要。仅 `confirming` 阶段非 nil；完整计划留在 Controller 私有状态里。
    let pendingPlan: DiskCleanPendingPlanSummary?
    /// 权威选择状态的只读投影（设计 §8.1）。菜单栏与详情页读同一份。
    let selection: DiskCleanSelectionProjection

    init(
        phase: DiskCleanControllerPhase,
        scope: DiskCleanScanScope,
        scanResult: DiskCleanScanResult?,
        executionResult: DiskCleanExecutionResult?,
        isResultStale: Bool,
        isResultExpired: Bool = false,
        errorMessage: String?,
        scanLogEntries: [DiskCleanScanLogEntry] = [],
        removalMode: DiskCleanRemovalMode = .trash,
        pendingPlan: DiskCleanPendingPlanSummary? = nil,
        selection: DiskCleanSelectionProjection = .empty
    ) {
        self.phase = phase
        self.scope = scope
        self.scanResult = scanResult
        self.executionResult = executionResult
        self.isResultStale = isResultStale
        self.isResultExpired = isResultExpired
        self.errorMessage = errorMessage
        self.scanLogEntries = scanLogEntries
        self.removalMode = removalMode
        self.pendingPlan = pendingPlan
        self.selection = selection
    }

    /// 规则段的勾选分组。其余分段没有分组概念，返回空集。
    var selectedChoices: Set<DiskCleanChoice> {
        scope.choices
    }

    var subtitle: String {
        subtitle()
    }

    func subtitle(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch phase {
        case .idle:
            return localization.string("controller.subtitle.idle", defaultValue: "选择清理范围")
        case .scanning:
            return localization.string("controller.subtitle.scanning", defaultValue: "正在扫描")
        case .scanned:
            if isResultStale {
                return localization.string("controller.subtitle.stale", defaultValue: "清理范围已变化")
            }
            if isResultExpired {
                return localization.string("controller.subtitle.expired", defaultValue: "结果已过期，请重新扫描")
            }
            return scanResult.map {
                localization.format(
                    "controller.subtitle.scannedCount",
                    defaultValue: "%d 项可清理",
                    $0.cleanableCandidates.count
                )
            } ?? localization.string("controller.subtitle.scanned", defaultValue: "扫描完成")
        case .confirming:
            return localization.string("controller.subtitle.confirming", defaultValue: "等待确认永久清理")
        case .cleaning:
            return localization.string("controller.subtitle.cleaning", defaultValue: "正在清理")
        case .completed:
            return localization.string("controller.subtitle.completed", defaultValue: "清理完成")
        }
    }

    var isBusy: Bool {
        phase == .scanning || phase == .cleaning
    }

    /// 范围为空即禁用扫描：规则段是一个分组都没勾，开发产物段是还没添加文件夹。
    /// 两种情况都要在界面上给引导，而不是让用户点一个什么都不会发生的按钮。
    var canScan: Bool {
        !isBusy && phase != .confirming && !scope.isEmpty
    }

    /// 可清理 = 有结果、结果新鲜、**且用户当前选中了东西**。
    /// 选中集空时按钮变灰而不是"清理全部"——菜单栏与详情页读的是同一份选择。
    var canClean: Bool {
        phase == .scanned
            && !isResultStale
            && !isResultExpired
            && !selection.isEmpty
    }

    static let initial = DiskCleanControllerSnapshot(
        phase: .idle,
        scope: .rules(choices: Set(DiskCleanChoice.allCases)),
        scanResult: nil,
        executionResult: nil,
        isResultStale: false,
        errorMessage: nil
    )
}

@MainActor
protocol DiskCleanControlling: AnyObject {
    var onStateChange: (() -> Void)? { get set }
    var snapshot: DiskCleanControllerSnapshot { get }

    /// 整体替换扫描范围。开发产物段的扫描根增删走这里。
    func setScope(_ scope: DiskCleanScanScope)
    /// 规则段的分组勾选。非规则范围下为空操作。
    func setChoice(_ choice: DiskCleanChoice, isSelected: Bool)
    func setRemovalMode(_ mode: DiskCleanRemovalMode)
    func setCandidateSelected(_ candidateID: DiskCleanCandidate.ID, isSelected: Bool)
    /// 分类级全选（`true` = 选中本类所有低风险项）/ 全不选。
    func setCategorySelection(_ category: DiskCleanCategoryID, isSelected: Bool)
    func scan()
    /// 清理当前选中集。不接收 id 参数——选中集只有一处权威（设计 §8.1）。
    func clean()
    func confirmPendingClean()
    func cancelPendingClean()
    func cancelCurrentOperation()
}

/// 状态机 + 事件流消费 + 过期时钟 + 确认窗口。
///
/// 四个机制原样保留：
/// - **operationID 世代**：每次操作换一个 UUID，过期操作的事件与收尾一律丢弃，
///   避免"上一次扫描的尾巴"污染新一轮状态。
/// - **节流发布**：扫描事件逐条到达但快照按 ~250ms 批量发布（AGENTS.md 高频源例外条款），
///   否则每个候选都会触发一次宿主重建。
/// - **日志环形上限**：最多保留 500 条。
/// - **快照单一出口**：所有状态发布都经 `publish`，`removalMode` 与 `pendingPlan`
///   一律从 Controller 私有状态派生，不可能出现"某个分支忘了带上待确认计划"。
@MainActor
final class DiskCleanController: ObservableObject, DiskCleanControlling {
    /// 扫描期快照发布间隔（设计 §8.2 的 ~250ms 节流）。
    private static let scanFlushIntervalNanoseconds: UInt64 = 250_000_000
    private static let maximumLogEntries = 500
    /// 确认窗口上限（设计 §8.4）。实际窗口取 `min(60s, 过期门剩余时间)`。
    static let confirmationWindow: TimeInterval = 60

    var onStateChange: (() -> Void)?

    @Published private(set) var snapshot: DiskCleanControllerSnapshot {
        didSet {
            onStateChange?()
        }
    }

    private let engine: any DiskCleanScanning
    private let executor: any DiskCleanExecuting
    private let localization: PluginLocalization
    private let clock: any DiskCleanClock
    private let removalModeStore: any DiskCleanRemovalModeStoring
    /// 铸造计划时查 target 的锁定声明。与 `DiskCleanScanEngine` 注入同一份目录。
    private let catalog: DiskCleanRuleCatalogV2

    private var currentTask: Task<Void, Never>?
    private var currentOperationID: UUID?
    private var scanFlushTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var confirmationTask: Task<Void, Never>?
    private var nextLogEntryID = 1

    private var removalMode: DiskCleanRemovalMode
    /// 冻结的待确认计划。`confirming` 阶段之外必须为 nil。
    private var pendingPlan: DiskCleanValidatedPlan?
    /// 权威选择状态（设计 §8.1）。视图只拿得到 `publish` 派生的只读投影。
    private var selection = DiskCleanSelectionModel()

    /// 扫描进行中的权威候选集。快照是它的投影，节流只影响发布时机，不影响正确性。
    private var liveCandidates: [DiskCleanCandidate] = []
    private var liveCandidateIndexByID: [DiskCleanCandidate.ID: Int] = [:]
    private var pendingLogMessages: [DiskCleanScanLogMessage] = []
    private var needsScanFlush = false

    init(
        engine: any DiskCleanScanning = DiskCleanScanEngine(),
        executor: any DiskCleanExecuting = DiskCleanExecutor(),
        initialSnapshot: DiskCleanControllerSnapshot = .initial,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        clock: any DiskCleanClock = DiskCleanSystemClock(),
        removalModeStore: any DiskCleanRemovalModeStoring = UserDefaultsDiskCleanRemovalModeStore(),
        catalog: DiskCleanRuleCatalogV2 = .current
    ) {
        self.engine = engine
        self.executor = executor
        self.localization = localization
        self.clock = clock
        self.removalModeStore = removalModeStore
        self.catalog = catalog
        self.removalMode = removalModeStore.load()
        snapshot = DiskCleanControllerSnapshot(
            phase: initialSnapshot.phase,
            scope: initialSnapshot.scope,
            scanResult: initialSnapshot.scanResult,
            executionResult: initialSnapshot.executionResult,
            isResultStale: initialSnapshot.isResultStale,
            isResultExpired: initialSnapshot.isResultExpired,
            errorMessage: initialSnapshot.errorMessage,
            scanLogEntries: initialSnapshot.scanLogEntries,
            removalMode: removalModeStore.load()
        )
    }

    deinit {
        currentTask?.cancel()
        scanFlushTask?.cancel()
        expiryTask?.cancel()
        confirmationTask?.cancel()
    }

    func setScope(_ scope: DiskCleanScanScope) {
        guard scope != snapshot.scope else { return }

        // 范围一变，冻结的计划就不再对应用户看到的内容——作废，不是悄悄沿用（§8.4）。
        discardPendingPlan()

        publish(
            phase: snapshot.phase == .confirming ? .scanned : snapshot.phase,
            scope: scope,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: isStale(scanResult: snapshot.scanResult, scope: scope),
            isResultExpired: snapshot.isResultExpired,
            errorMessage: snapshot.errorMessage,
            scanLogEntries: snapshot.scanLogEntries
        )
    }

    /// 非规则范围下静默忽略：分组这个概念只对规则段成立，为它伪造一个 `.rules` 范围
    /// 会把整个分段的扫描范围换掉。
    func setChoice(_ choice: DiskCleanChoice, isSelected: Bool) {
        guard case var .rules(nextChoices) = snapshot.scope else { return }
        if isSelected {
            nextChoices.insert(choice)
        } else {
            nextChoices.remove(choice)
        }
        setScope(.rules(choices: nextChoices))
    }

    func setCandidateSelected(_ candidateID: DiskCleanCandidate.ID, isSelected: Bool) {
        guard let index = liveCandidateIndexByID[candidateID] else { return }
        // 不可勾选的候选由模型直接拒绝——UI 禁用只是提示，真正的门在这里。
        guard selection.setCandidate(liveCandidates[index], isSelected: isSelected) else { return }
        publishSelectionChange()
    }

    func setCategorySelection(_ category: DiskCleanCategoryID, isSelected: Bool) {
        selection.setCategory(category, isSelected: isSelected)
        publishSelectionChange()
    }

    /// 选择变更后的统一收尾：作废冻结计划并重新发布快照。
    ///
    /// 冻结的计划对应的是用户按下确认那一刻看到的选中集，选择一变它就不再对应任何用户意图（§8.4）。
    private func publishSelectionChange() {
        let wasConfirming = snapshot.phase == .confirming
        discardPendingPlan()
        publish(
            phase: wasConfirming ? .scanned : snapshot.phase,
            scope: snapshot.scope,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: snapshot.isResultStale,
            isResultExpired: snapshot.isResultExpired,
            errorMessage: snapshot.errorMessage,
            scanLogEntries: snapshot.scanLogEntries
        )
    }

    func setRemovalMode(_ mode: DiskCleanRemovalMode) {
        guard mode != removalMode else { return }
        removalMode = mode
        removalModeStore.save(mode)

        // 删除方式是冻结进计划的字段之一，变更必须作废待确认计划（§8.4）。
        let wasConfirming = snapshot.phase == .confirming
        discardPendingPlan()
        publish(
            phase: wasConfirming ? .scanned : snapshot.phase,
            scope: snapshot.scope,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: snapshot.isResultStale,
            isResultExpired: snapshot.isResultExpired,
            errorMessage: snapshot.errorMessage,
            scanLogEntries: snapshot.scanLogEntries
        )
    }

    func scan() {
        guard snapshot.canScan else { return }

        // 过期后的重扫必须绕过缓存，否则"过期 → 重扫 → 命中旧缓存 → 仍过期"会死循环（设计 §4.3）。
        let forceRefresh = snapshot.isResultExpired
        cancelTaskOnly()
        discardPendingPlan()

        let scope = snapshot.scope
        let operationID = UUID()
        currentOperationID = operationID
        nextLogEntryID = 1
        liveCandidates = []
        liveCandidateIndexByID = [:]
        pendingLogMessages = []
        needsScanFlush = false
        // 候选 ID 跨扫描稳定，不重置会把上一轮的勾选悄悄带进新结果。
        selection.reset()

        publish(
            phase: .scanning,
            scope: scope,
            scanResult: nil,
            executionResult: nil,
            isResultStale: false,
            isResultExpired: false,
            errorMessage: nil,
            scanLogEntries: [
                makeLogEntry(
                    DiskCleanScanLogMessage(
                        text: localization.format(
                            "scanLog.started",
                            defaultValue: "开始扫描：%@",
                            scopeDescription(scope)
                        ),
                        tone: .info
                    )
                )
            ]
        )
        startScanFlushLoop(operationID: operationID)

        let stream = engine.scan(scope: scope, forceRefresh: forceRefresh)
        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    guard isCurrentOperation(operationID) else { return }
                    handle(event, operationID: operationID, scope: scope)
                }
                guard isCurrentOperation(operationID) else { return }
                finishOperation(operationID)
            } catch is CancellationError {
                guard isCurrentOperation(operationID) else { return }
                publishCancelledScan(scope: scope)
                finishOperation(operationID)
            } catch {
                guard isCurrentOperation(operationID) else { return }
                publishFailedScan(scope: scope, error: error)
                finishOperation(operationID)
            }
        }
    }

    /// 清理入口。铸造计划 → 废纸篓直执 / 永久进确认（设计 §8.4）。
    ///
    /// 清理集合直接取自权威选择模型：菜单栏与详情页不各自持有一份"要清理什么"的理解。
    func clean() {
        guard snapshot.canClean, let scanResult = snapshot.scanResult else { return }
        // Planner 的唯一输入是扫描工件。没有工件（扫描中断、旧投影）就没有计划，也就没有删除。
        guard let artifact = scanResult.artifact else { return }

        // §3.1 不变量的第一道防线：未定大小或 partial 的候选**绝不**进入清理集合。
        // 选择模型本身已拒绝勾选它们，这里的交集是对"投影与候选事实脱节"的兜底。
        // （Planner 与执行器各自还有一道。）
        let cleanableIDs = Set(scanResult.cleanableCandidates.map(\.id))
        let selectedIDs = cleanableIDs.intersection(snapshot.selection.selectedIDs)
        guard !selectedIDs.isEmpty else { return }

        let plan: DiskCleanValidatedPlan
        do {
            plan = try DiskCleanPlanner.makePlan(
                artifact: artifact,
                selectedIDs: selectedIDs,
                mode: removalMode,
                now: clock.now,
                catalog: catalog
            )
        } catch {
            // 铸造失败 = 零删除。原因如实告诉用户，不降级成"部分清理"。
            publish(
                phase: .scanned,
                scope: snapshot.scope,
                scanResult: scanResult,
                executionResult: nil,
                isResultStale: snapshot.isResultStale,
                isResultExpired: isExpired(scanResult),
                errorMessage: Self.userFacingMessage(for: error),
                scanLogEntries: snapshot.scanLogEntries
            )
            return
        }

        switch plan.mode {
        case .trash:
            // 冻结原语保证可恢复，故单步执行，不设二次确认。
            startExecution(plan: plan, scanResult: scanResult)
        case .permanent:
            enterConfirming(plan: plan, scanResult: scanResult)
        }
    }

    func confirmPendingClean() {
        guard snapshot.phase == .confirming,
              let plan = pendingPlan,
              let scanResult = snapshot.scanResult else { return }
        startExecution(plan: plan, scanResult: scanResult)
    }

    func cancelPendingClean() {
        guard snapshot.phase == .confirming else { return }
        invalidatePendingPlan(errorMessage: nil)
    }

    func cancelCurrentOperation() {
        let phase = snapshot.phase
        let scope = snapshot.scope
        let scanResult = snapshot.scanResult
        let isResultStale = snapshot.isResultStale
        let isResultExpired = snapshot.isResultExpired
        let scanLogEntries = snapshot.scanLogEntries

        switch phase {
        case .confirming:
            invalidatePendingPlan(errorMessage: nil)
        case .scanning:
            cancelTaskOnly()
            publish(
                phase: .idle,
                scope: scope,
                scanResult: nil,
                executionResult: nil,
                isResultStale: false,
                isResultExpired: false,
                errorMessage: nil,
                scanLogEntries: scanLogEntries + [
                    makeLogEntry(
                        DiskCleanScanLogMessage(
                            text: localization.string("scanLog.stopped", defaultValue: "扫描已停止"),
                            tone: .warning
                        )
                    )
                ]
            )
        case .cleaning:
            cancelTaskOnly()
            publish(
                phase: .scanned,
                scope: scope,
                scanResult: scanResult,
                executionResult: nil,
                isResultStale: isResultStale,
                isResultExpired: isResultExpired,
                errorMessage: nil,
                scanLogEntries: scanLogEntries
            )
        case .idle, .scanned, .completed:
            cancelTaskOnly()
        }
    }

    // MARK: - 确认与执行

    private func enterConfirming(plan: DiskCleanValidatedPlan, scanResult: DiskCleanScanResult) {
        pendingPlan = plan
        publish(
            phase: .confirming,
            scope: snapshot.scope,
            scanResult: scanResult,
            executionResult: nil,
            isResultStale: snapshot.isResultStale,
            isResultExpired: false,
            errorMessage: nil,
            scanLogEntries: snapshot.scanLogEntries
        )

        // 确认窗口不得越过过期时刻：299 秒时铸造 + 60 秒确认窗口，否则会在门限之外落下。
        let deadline = min(clock.now.addingTimeInterval(Self.confirmationWindow), plan.expiryDeadline)
        confirmationTask?.cancel()
        confirmationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled, snapshot.phase == .confirming else { return }
            invalidatePendingPlan(
                errorMessage: localization.string(
                    "controller.error.confirmationExpired",
                    defaultValue: "确认已超时，请重新发起清理"
                )
            )
        }
    }

    /// 作废待确认计划并回到 `scanned`。
    private func invalidatePendingPlan(errorMessage: String?) {
        discardPendingPlan()
        publish(
            phase: .scanned,
            scope: snapshot.scope,
            scanResult: snapshot.scanResult,
            executionResult: nil,
            isResultStale: snapshot.isResultStale,
            isResultExpired: snapshot.scanResult.map(isExpired) ?? false,
            errorMessage: errorMessage,
            scanLogEntries: snapshot.scanLogEntries
        )
    }

    private func discardPendingPlan() {
        pendingPlan = nil
        confirmationTask?.cancel()
        confirmationTask = nil
    }

    private func startExecution(plan: DiskCleanValidatedPlan, scanResult: DiskCleanScanResult) {
        cancelTaskOnly()
        discardPendingPlan()

        let scope = snapshot.scope
        let operationID = UUID()
        currentOperationID = operationID
        publish(
            phase: .cleaning,
            scope: scope,
            scanResult: scanResult,
            executionResult: nil,
            isResultStale: false,
            isResultExpired: false,
            errorMessage: nil,
            scanLogEntries: snapshot.scanLogEntries
        )

        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let executionResult = try await executor.execute(plan: plan)
                guard isCurrentOperation(operationID) else { return }
                publishCleaning(
                    phase: .completed,
                    scope: scope,
                    scanResult: scanResult,
                    executionResult: executionResult,
                    errorMessage: nil
                )
                finishOperation(operationID)
            } catch is CancellationError {
                guard isCurrentOperation(operationID) else { return }
                publishCleaning(
                    phase: .scanned,
                    scope: scope,
                    scanResult: scanResult,
                    executionResult: nil,
                    errorMessage: nil
                )
                finishOperation(operationID)
            } catch {
                // preflight 失败即零删除，如实报因由（§7.1）。
                guard isCurrentOperation(operationID) else { return }
                publishCleaning(
                    phase: .scanned,
                    scope: scope,
                    scanResult: scanResult,
                    executionResult: nil,
                    errorMessage: Self.userFacingMessage(for: error)
                )
                finishOperation(operationID)
            }
        }
    }

    // MARK: - 事件消费

    private func handle(
        _ event: DiskCleanScanEvent,
        operationID: UUID,
        scope: DiskCleanScanScope
    ) {
        switch event {
        case let .log(message):
            pendingLogMessages.append(message)
            needsScanFlush = true

        case let .candidateFound(candidate):
            liveCandidateIndexByID[candidate.id] = liveCandidates.count
            liveCandidates.append(candidate)
            needsScanFlush = true

        case let .candidateSized(candidateID, result):
            guard let index = liveCandidateIndexByID[candidateID] else { return }
            liveCandidates[index] = liveCandidates[index].applying(result)
            needsScanFlush = true

        case .categoryFinished:
            // 不消费：逐项的"计算中"徽标已经把进度说清楚了，再加一个分类级 spinner
            // 只是在同一件事上多一种表述。事件本身保留，供 P2 分段（§10）按分类收尾时使用。
            break

        case let .finished(summary):
            publishFinishedScan(summary: summary, scope: scope)
        }
    }

    private func startScanFlushLoop(operationID: UUID) {
        scanFlushTask?.cancel()
        scanFlushTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.scanFlushIntervalNanoseconds)
                } catch {
                    return
                }
                guard let self, isCurrentOperation(operationID) else { return }
                flushScanUpdates(operationID: operationID)
            }
        }
    }

    private func flushScanUpdates(operationID: UUID) {
        guard needsScanFlush, isCurrentOperation(operationID), snapshot.phase == .scanning else { return }
        needsScanFlush = false

        publish(
            phase: .scanning,
            scope: snapshot.scope,
            scanResult: DiskCleanScanResult(
                scope: snapshot.scope,
                candidates: liveCandidates,
                scannedAt: clock.now
            ),
            executionResult: nil,
            isResultStale: false,
            isResultExpired: false,
            errorMessage: nil,
            scanLogEntries: scanLogEntries(adding: drainPendingLogMessages(), to: snapshot.scanLogEntries)
        )
    }

    private func publishFinishedScan(summary: DiskCleanScanSummary, scope: DiskCleanScanScope) {
        needsScanFlush = false
        let artifact = summary.artifact
        liveCandidates = artifact.candidates
        liveCandidateIndexByID = Dictionary(
            artifact.candidates.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        let scanResult = DiskCleanScanResult(
            scope: scope,
            candidates: artifact.candidates,
            scannedAt: artifact.finishedAt,
            limitations: artifact.limitations,
            artifact: artifact
        )
        publish(
            phase: .scanned,
            scope: snapshot.scope,
            scanResult: scanResult,
            executionResult: nil,
            isResultStale: isStale(scanResult: scanResult, scope: snapshot.scope),
            isResultExpired: isExpired(scanResult),
            errorMessage: nil,
            scanLogEntries: scanLogEntries(adding: drainPendingLogMessages(), to: snapshot.scanLogEntries)
        )
        scheduleExpiry(for: scanResult)
    }

    private func publishCancelledScan(scope: DiskCleanScanScope) {
        publish(
            phase: .idle,
            scope: scope,
            scanResult: nil,
            executionResult: nil,
            isResultStale: false,
            isResultExpired: false,
            errorMessage: nil,
            scanLogEntries: scanLogEntries(adding: drainPendingLogMessages(), to: snapshot.scanLogEntries)
        )
    }

    private func publishFailedScan(scope: DiskCleanScanScope, error: Error) {
        let message = Self.userFacingMessage(for: error)
        publish(
            phase: .idle,
            scope: scope,
            scanResult: nil,
            executionResult: nil,
            isResultStale: false,
            isResultExpired: false,
            errorMessage: message,
            scanLogEntries: scanLogEntries(
                adding: drainPendingLogMessages() + [
                    DiskCleanScanLogMessage(
                        text: localization.format("scanLog.failed", defaultValue: "扫描失败：%@", message),
                        tone: .error
                    )
                ],
                to: snapshot.scanLogEntries
            )
        )
    }

    private func publishCleaning(
        phase: DiskCleanControllerPhase,
        scope: DiskCleanScanScope,
        scanResult: DiskCleanScanResult,
        executionResult: DiskCleanExecutionResult?,
        errorMessage: String?
    ) {
        publish(
            phase: phase,
            scope: scope,
            scanResult: scanResult,
            executionResult: executionResult,
            isResultStale: false,
            isResultExpired: phase == .scanned ? isExpired(scanResult) : false,
            errorMessage: errorMessage,
            scanLogEntries: snapshot.scanLogEntries
        )
        // 回到 scanned 意味着结果还能再用一次，过期时钟必须跟着重新挂上。
        if phase == .scanned {
            scheduleExpiry(for: scanResult)
        }
    }

    // MARK: - 快照发布

    /// 快照的唯一出口。`removalMode`、`pendingPlan` 与 `selection` 一律从私有状态派生。
    ///
    /// 选择投影在这里现算（而不是由各调用点传入），因此它与本次发布的候选集必然一致——
    /// 不存在"某个分支发布了新候选却带着旧选择"的可能。
    private func publish(
        phase: DiskCleanControllerPhase,
        scope: DiskCleanScanScope,
        scanResult: DiskCleanScanResult?,
        executionResult: DiskCleanExecutionResult?,
        isResultStale: Bool,
        isResultExpired: Bool,
        errorMessage: String?,
        scanLogEntries: [DiskCleanScanLogEntry]
    ) {
        snapshot = DiskCleanControllerSnapshot(
            phase: phase,
            scope: scope,
            scanResult: scanResult,
            executionResult: executionResult,
            isResultStale: isResultStale,
            isResultExpired: isResultExpired,
            errorMessage: errorMessage,
            scanLogEntries: scanLogEntries,
            removalMode: removalMode,
            pendingPlan: pendingPlan.map {
                DiskCleanPendingPlanSummary(
                    itemCount: $0.itemCount,
                    totalEstimatedBytes: $0.totalEstimatedBytes,
                    mode: $0.mode
                )
            },
            selection: selection.projection(for: scanResult?.candidates ?? [])
        )
    }

    // MARK: - 过期门

    /// 时间驱动的过期转换（设计 §4.4）：门限到点即发 `onStateChange`，
    /// 菜单栏按钮与详情页同步变灰，不依赖用户操作才发现过期。
    private func scheduleExpiry(for scanResult: DiskCleanScanResult) {
        expiryTask?.cancel()
        expiryTask = nil

        guard let deadline = scanResult.expiryDeadline, clock.now < deadline else { return }

        expiryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            markResultExpired()
        }
    }

    private func markResultExpired() {
        // 确认窗口不会越过过期时刻，但两者同时到点时次序不定：过期先到就在这里作废计划。
        if snapshot.phase == .confirming {
            discardPendingPlan()
        }
        guard snapshot.phase == .scanned || snapshot.phase == .confirming, !snapshot.isResultExpired else { return }
        publish(
            phase: .scanned,
            scope: snapshot.scope,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: snapshot.isResultStale,
            isResultExpired: true,
            errorMessage: snapshot.errorMessage,
            scanLogEntries: snapshot.scanLogEntries
        )
    }

    private func isExpired(_ scanResult: DiskCleanScanResult) -> Bool {
        guard let deadline = scanResult.expiryDeadline else { return false }
        return clock.now >= deadline
    }

    // MARK: - 收尾与工具

    private func cancelTaskOnly() {
        currentTask?.cancel()
        currentTask = nil
        currentOperationID = nil
        scanFlushTask?.cancel()
        scanFlushTask = nil
        expiryTask?.cancel()
        expiryTask = nil
    }

    private func finishOperation(_ operationID: UUID) {
        guard isCurrentOperation(operationID) else { return }
        currentTask = nil
        currentOperationID = nil
        scanFlushTask?.cancel()
        scanFlushTask = nil
    }

    private func drainPendingLogMessages() -> [DiskCleanScanLogMessage] {
        defer { pendingLogMessages.removeAll(keepingCapacity: true) }
        return pendingLogMessages
    }

    private func scanLogEntries(
        adding messages: [DiskCleanScanLogMessage],
        to existingEntries: [DiskCleanScanLogEntry]
    ) -> [DiskCleanScanLogEntry] {
        guard !messages.isEmpty else { return existingEntries }

        var entries = existingEntries
        entries.reserveCapacity(min(existingEntries.count + messages.count, Self.maximumLogEntries))
        for message in messages {
            entries.append(makeLogEntry(message))
        }
        if entries.count > Self.maximumLogEntries {
            entries.removeFirst(entries.count - Self.maximumLogEntries)
        }
        return entries
    }

    private func makeLogEntry(_ message: DiskCleanScanLogMessage) -> DiskCleanScanLogEntry {
        defer { nextLogEntryID += 1 }
        return DiskCleanScanLogEntry(
            id: nextLogEntryID,
            text: message.text,
            tone: message.tone
        )
    }

    /// 扫描开始日志里的范围描述。
    private func scopeDescription(_ scope: DiskCleanScanScope) -> String {
        let separator = localization.string("list.separator", defaultValue: "、")
        switch scope {
        case let .rules(choices):
            return DiskCleanChoice.allCases
                .filter { choices.contains($0) }
                .map { $0.title(localization: localization) }
                .joined(separator: separator)
        case let .developerArtifacts(roots):
            return roots.joined(separator: separator)
        case .installers:
            return DiskCleanCategoryID.installers.title(localization: localization)
        }
    }

    private func isCurrentOperation(_ operationID: UUID) -> Bool {
        currentOperationID == operationID
    }

    /// 结果与当前范围不一致。开发产物段因此在用户增删扫描根后同样提示"请重新扫描"——
    /// 与规则段改分组是同一件事。
    private func isStale(
        scanResult: DiskCleanScanResult?,
        scope: DiskCleanScanScope
    ) -> Bool {
        guard let scanResult else { return false }
        return scanResult.scope != scope
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
