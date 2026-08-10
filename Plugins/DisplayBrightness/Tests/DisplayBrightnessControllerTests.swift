import AppKit
import CoreGraphics
import XCTest
import MacToolsPluginKit
@testable import DisplayBrightnessPlugin

@MainActor
final class DisplayBrightnessControllerTests: XCTestCase {
    func testAwaitedWriteReportsItsOwnFailureWhenLaterWriteSucceeds() async {
        let display = makeTestDisplay(id: 7, name: "Studio Display")
        let backend = ScriptedBrightnessBackend(
            display: display,
            results: [.failure(TestWriteError.failed), .success(())],
            suspendsFirstWrite: true
        )
        let controller = makeController(display: display, backend: backend)
        controller.refresh()

        let actionResult = Task {
            await controller.setBrightnessAndWait(0.4, for: display.id)
        }
        await waitUntil { backend.firstWriteStarted }
        controller.setBrightness(0.8, for: display.id, phase: .ended)
        backend.releaseFirstWrite()

        let result = await actionResult.value
        await waitUntil { backend.writeValues.count == 2 }

        guard case .failed = result else {
            return XCTFail("Expected the failed 0.4 write to fail its own waiter")
        }
        XCTAssertEqual(backend.writeValues, [0.4, 0.8])
    }

    func testAwaitedPendingWriteFailsWhenSupersededBeforeItStarts() async {
        let display = makeTestDisplay(id: 9, name: "LG UltraFine")
        let backend = ScriptedBrightnessBackend(
            display: display,
            results: [.success(()), .success(())],
            suspendsFirstWrite: true
        )
        let controller = makeController(display: display, backend: backend)
        controller.refresh()
        controller.setBrightness(0.2, for: display.id, phase: .ended)
        await waitUntil { backend.firstWriteStarted }

        let actionResult = Task {
            await controller.setBrightnessAndWait(0.4, for: display.id)
        }
        await waitUntil {
            controller.snapshot().displays.first?.brightness == 0.4
        }
        controller.setBrightness(0.8, for: display.id, phase: .ended)
        backend.releaseFirstWrite()

        let result = await actionResult.value
        await waitUntil { backend.writeValues.count == 2 }

        guard case .failed = result else {
            return XCTFail("Expected the superseded 0.4 write to fail")
        }
        XCTAssertEqual(backend.writeValues, [0.2, 0.8])
    }

    func testInFlightWriteWaitsForActualOutcomePastTimeout() async {
        let display = makeTestDisplay(id: 11, name: "Pro Display XDR")
        let backend = ScriptedBrightnessBackend(
            display: display,
            results: [.success(())],
            suspendsFirstWrite: true
        )
        let controller = makeController(
            display: display,
            backend: backend,
            writeTimeout: .milliseconds(20)
        )
        controller.refresh()
        var observedResult: DisplayBrightnessWriteResult?

        let actionResult = Task { @MainActor in
            let result = await controller.setBrightnessAndWait(0.4, for: display.id)
            observedResult = result
            return result
        }
        await waitUntil { backend.firstWriteStarted }
        await waitUntil { controller.pendingWriteTimeoutCount == 0 }

        XCTAssertNil(observedResult, "an in-flight backend write must not report timeout before its real outcome")
        backend.releaseFirstWrite()
        let result = await actionResult.value

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(
            controller.snapshot().displays.first?.brightness ?? -1,
            0.4,
            accuracy: 0.0001
        )
    }

    func testPendingWriteStillTimesOutBeforeBackendDispatch() async {
        let display = makeTestDisplay(id: 13, name: "Studio Display")
        let backend = ScriptedBrightnessBackend(
            display: display,
            results: [.success(()), .success(())],
            suspendsFirstWrite: true
        )
        let controller = makeController(
            display: display,
            backend: backend,
            writeTimeout: .milliseconds(20)
        )
        controller.refresh()
        controller.setBrightness(0.2, for: display.id, phase: .ended)
        await waitUntil { backend.firstWriteStarted }

        let result = await controller.setBrightnessAndWait(0.8, for: display.id)

        guard case .failed = result else {
            backend.releaseFirstWrite()
            return XCTFail("Expected a queued write to time out, got \(result)")
        }
        XCTAssertEqual(backend.writeValues, [0.2], "a timed-out pending write must never reach the backend")
        backend.releaseFirstWrite()
    }

    func testDisconnectedInFlightWriteReportsActualSuccess() async {
        let display = makeTestDisplay(id: 15, name: "Studio Display")
        let provider = MutableDisplayProvider(displays: [display])
        let backend = ScriptedBrightnessBackend(
            display: display,
            results: [.success(())],
            suspendsFirstWrite: true
        )
        let controller = makeController(
            display: display,
            backend: backend,
            writeTimeout: .milliseconds(20),
            displayProvider: provider
        )
        controller.refresh()
        var observedResult: DisplayBrightnessWriteResult?
        let resultTask = Task { @MainActor in
            let result = await controller.setBrightnessAndWait(0.4, for: display.id)
            observedResult = result
            return result
        }
        await waitUntil { backend.firstWriteStarted }

        provider.displays = []
        controller.refresh()
        await waitUntil { controller.pendingWriteTimeoutCount == 0 }

        XCTAssertNil(observedResult)
        XCTAssertTrue(controller.snapshot().displays.isEmpty)
        backend.releaseFirstWrite()

        let result = await resultTask.value
        XCTAssertEqual(result, .succeeded)
    }

    func testDisconnectedInFlightWriteReportsActualFailure() async {
        let display = makeTestDisplay(id: 17, name: "Studio Display")
        let provider = MutableDisplayProvider(displays: [display])
        let backend = ScriptedBrightnessBackend(
            display: display,
            results: [.failure(TestWriteError.failed)],
            suspendsFirstWrite: true
        )
        let controller = makeController(
            display: display,
            backend: backend,
            displayProvider: provider
        )
        controller.refresh()
        var observedResult: DisplayBrightnessWriteResult?
        let resultTask = Task { @MainActor in
            let result = await controller.setBrightnessAndWait(0.4, for: display.id)
            observedResult = result
            return result
        }
        await waitUntil { backend.firstWriteStarted }

        provider.displays = []
        controller.refresh()
        XCTAssertNil(observedResult)
        backend.releaseFirstWrite()

        guard case .failed = await resultTask.value else {
            return XCTFail("Expected the disconnected backend failure to be reported")
        }
    }

    func testLifecycleCancellationDropsPendingWriteBeforeDispatch() async {
        let display = makeTestDisplay(id: 19, name: "Studio Display")
        let backend = ScriptedBrightnessBackend(
            display: display,
            results: [.success(()), .success(())],
            suspendsFirstWrite: true
        )
        let controller = makeController(display: display, backend: backend)
        controller.refresh()
        controller.setBrightness(0.2, for: display.id, phase: .ended)
        await waitUntil { backend.firstWriteStarted }
        let pendingResult = Task {
            await controller.setBrightnessAndWait(0.8, for: display.id)
        }
        await waitUntil {
            controller.snapshot().displays.first?.brightness == 0.8
        }

        controller.cancelOutstandingWrites()
        guard case .failed = await pendingResult.value else {
            backend.releaseFirstWrite()
            return XCTFail("Expected the pending write to be cancelled")
        }
        XCTAssertEqual(backend.writeValues, [0.2])
        backend.releaseFirstWrite()
    }

    func testReactivationDoesNotLetRetiredFailureFallbackIntoNewDisplayState() async {
        let display = makeTestDisplay(id: 21, name: "Studio Display")
        let provider = MutableDisplayProvider(displays: [display])
        let retiredBackend = ScriptedBrightnessBackend(
            display: display,
            results: [.failure(TestWriteError.failed)],
            suspendsFirstWrite: true
        )
        let replacementBackend = ScriptedBrightnessBackend(
            display: display,
            results: [.success(())],
            suspendsFirstWrite: false
        )
        let builder = SequencedBrightnessBackendBuilder(
            backends: [retiredBackend, replacementBackend]
        )
        let controller = DisplayBrightnessController(
            displayProvider: provider,
            backendBuilder: builder,
            shortWriteDelay: 0,
            minimumWriteInterval: 0,
            writeTimeout: .seconds(10)
        )
        controller.refresh()
        let resultTask = Task {
            await controller.setBrightnessAndWait(0.4, for: display.id)
        }
        await waitUntil { retiredBackend.firstWriteStarted }

        controller.cancelOutstandingWrites()
        controller.refresh()
        retiredBackend.releaseFirstWrite()

        guard case .failed = await resultTask.value else {
            return XCTFail("Expected the retired backend's real failure")
        }
        await waitUntil { retiredBackend.cleanupCount == 1 }
        XCTAssertEqual(builder.fallbackCallCount, 0)
        XCTAssertTrue(replacementBackend.writeValues.isEmpty)
        XCTAssertEqual(
            controller.snapshot().displays.first?.brightness ?? -1,
            1,
            accuracy: 0.0001
        )
    }

    private func makeController(
        display: DisplayInfo,
        backend: ScriptedBrightnessBackend,
        writeTimeout: Duration = .seconds(10),
        displayProvider: (any DisplayProviding)? = nil
    ) -> DisplayBrightnessController {
        DisplayBrightnessController(
            displayProvider: displayProvider ?? StaticDisplayProvider(display: display),
            backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0,
            writeTimeout: writeTimeout
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock().now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

private final class MutableDisplayProvider: DisplayProviding {
    var displays: [DisplayInfo]

    init(displays: [DisplayInfo]) {
        self.displays = displays
    }

    func listConnectedDisplays() -> [DisplayInfo] { displays }
    func screen(for displayID: CGDirectDisplayID) -> NSScreen? { nil }
}

private struct StaticDisplayProvider: DisplayProviding {
    let display: DisplayInfo

    func listConnectedDisplays() -> [DisplayInfo] { [display] }
    func screen(for displayID: CGDirectDisplayID) -> NSScreen? { nil }
}

private struct StaticBrightnessBackendBuilder: DisplayBrightnessBackendBuilding {
    let backend: ScriptedBrightnessBackend

    func backends(
        for displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend]
    ) -> [CGDirectDisplayID: any DisplayBrightnessBackend] {
        [backend.display.id: backend]
    }
}

private final class SequencedBrightnessBackendBuilder: DisplayBrightnessBackendBuilding {
    private let sequence: [ScriptedBrightnessBackend]
    private var buildIndex = 0
    private(set) var fallbackCallCount = 0

    init(backends: [ScriptedBrightnessBackend]) {
        sequence = backends
    }

    func backends(
        for displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend]
    ) -> [CGDirectDisplayID: any DisplayBrightnessBackend] {
        guard let display = displays.first,
              !sequence.isEmpty else {
            return [:]
        }
        let backend = sequence[min(buildIndex, sequence.count - 1)]
        buildIndex += 1
        return [display.id: backend]
    }

    func fallbackBackend(
        after failedBackend: any DisplayBrightnessBackend,
        for display: DisplayInfo,
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend]
    ) -> (any DisplayBrightnessBackend)? {
        fallbackCallCount += 1
        return nil
    }
}

private enum TestWriteError: Error {
    case failed
}

private final class ScriptedBrightnessBackend: DisplayBrightnessBackend, @unchecked Sendable {
    let kind: DisplayBrightnessBackendKind = .appleNative
    var display: DisplayInfo

    private let lock = NSLock()
    private let firstWriteGate = DispatchSemaphore(value: 0)
    private var brightness = 1.0
    private var results: [Result<Void, Error>]
    private let suspendsFirstWrite: Bool
    private var didStartFirstWrite = false
    private var writes: [Double] = []
    private var cleanups = 0

    init(
        display: DisplayInfo,
        results: [Result<Void, Error>],
        suspendsFirstWrite: Bool
    ) {
        self.display = display
        self.results = results
        self.suspendsFirstWrite = suspendsFirstWrite
    }

    var firstWriteStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStartFirstWrite
    }

    var writeValues: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    var cleanupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cleanups
    }

    func readBrightness() throws -> Double {
        lock.lock()
        defer { lock.unlock() }
        return brightness
    }

    func writeBrightness(_ value: Double) throws {
        lock.lock()
        let writeIndex = writes.count
        writes.append(value)
        if writeIndex == 0 {
            didStartFirstWrite = true
        }
        let result = results.isEmpty ? .success(()) : results.removeFirst()
        lock.unlock()

        if writeIndex == 0, suspendsFirstWrite {
            firstWriteGate.wait()
        }
        try result.get()

        lock.lock()
        brightness = value
        lock.unlock()
    }

    func releaseFirstWrite() {
        firstWriteGate.signal()
    }

    func cleanup() {
        lock.lock()
        cleanups += 1
        lock.unlock()
    }
}
