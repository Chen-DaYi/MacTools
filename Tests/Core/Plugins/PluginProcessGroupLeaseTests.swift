import Darwin
import XCTest
@testable import MacToolsPluginKit

final class PluginProcessGroupLeaseTests: XCTestCase {
    func testMemberListingTreatsSizesAsPIDCountsAndRetriesAFullBuffer() {
        let operation = ProcessGroupListOperation(
            estimatedCount: 12,
            returnedProcessIDs: Array(1...21).map(pid_t.init)
        )

        XCTAssertEqual(
            PluginProcessGroupLease.listGroupMembers(
                processGroupID: 42,
                list: { processGroupID, buffer, bufferSize in
                    operation.call(
                        processGroupID: processGroupID,
                        buffer: buffer,
                        bufferSize: bufferSize
                    )
                }
            ),
            Array(1...21).map(pid_t.init)
        )
        XCTAssertEqual(operation.requestedCapacities, [20, 40])
    }

    func testMemberListingDistinguishesAnErrorFromAnEmptyGroup() {
        let failed = ProcessGroupListOperation(
            estimatedCount: 0,
            returnedProcessIDs: [],
            sizingErrno: EIO
        )
        let empty = ProcessGroupListOperation(
            estimatedCount: 0,
            returnedProcessIDs: []
        )

        XCTAssertNil(
            PluginProcessGroupLease.listGroupMembers(
                processGroupID: 42,
                list: { processGroupID, buffer, bufferSize in
                    failed.call(
                        processGroupID: processGroupID,
                        buffer: buffer,
                        bufferSize: bufferSize
                    )
                }
            )
        )
        XCTAssertEqual(
            PluginProcessGroupLease.listGroupMembers(
                processGroupID: 42,
                list: { processGroupID, buffer, bufferSize in
                    empty.call(
                        processGroupID: processGroupID,
                        buffer: buffer,
                        bufferSize: bufferSize
                    )
                }
            ),
            []
        )
    }

    func testSignalsAndMembershipStopAfterLeaderIsReaped() {
        let events = ProcessLeaseEventLog()
        let lease = PluginProcessGroupLease(
            processID: 4242,
            operations: PluginProcessGroupLease.SystemOperations(
                waitForExitWithoutReaping: { processID in
                    events.append("observe:\(processID)")
                    return true
                },
                reap: { processID in
                    events.append("reap:\(processID)")
                    return 0
                },
                signalGroup: { processID, signal in
                    events.append("signal:\(processID):\(signal)")
                    return true
                },
                groupMembers: { processID in
                    events.append("members:\(processID)")
                    return [processID, 4243]
                }
            )
        )

        XCTAssertTrue(lease.waitForLeaderExit())
        XCTAssertTrue(lease.signal(SIGTERM))
        XCTAssertEqual(lease.remainingMemberPIDs(), [4243])
        XCTAssertEqual(lease.reapLeader(), 0)
        XCTAssertFalse(lease.signal(SIGKILL))
        XCTAssertNil(lease.remainingMemberPIDs())
        XCTAssertNil(lease.reapLeader())
        XCTAssertEqual(events.values, [
            "observe:4242",
            "signal:4242:\(SIGTERM)",
            "members:4242",
            "reap:4242",
        ])
    }

    func testObservationFailureRevokesGroupControlButStillAllowsReaping() {
        let events = ProcessLeaseEventLog()
        let lease = PluginProcessGroupLease(
            processID: 5252,
            operations: PluginProcessGroupLease.SystemOperations(
                waitForExitWithoutReaping: { processID in
                    events.append("observe:\(processID)")
                    return false
                },
                reap: { processID in
                    events.append("reap:\(processID)")
                    return 7 << 8
                },
                signalGroup: { processID, signal in
                    events.append("unexpected-signal:\(processID):\(signal)")
                    return true
                },
                groupMembers: { processID in
                    events.append("unexpected-members:\(processID)")
                    return [processID, 5253]
                }
            )
        )

        XCTAssertFalse(lease.waitForLeaderExit())
        XCTAssertFalse(lease.signal(SIGTERM))
        XCTAssertNil(lease.remainingMemberPIDs())
        XCTAssertEqual(lease.reapLeader(), 7 << 8)
        XCTAssertFalse(lease.signal(SIGKILL))
        XCTAssertNil(lease.remainingMemberPIDs())
        XCTAssertNil(lease.reapLeader())
        XCTAssertEqual(events.values, [
            "observe:5252",
            "reap:5252",
        ])
    }
}

private final class ProcessGroupListOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let estimatedCount: Int32
    private let returnedProcessIDs: [pid_t]
    private let sizingErrno: Int32
    private var capacities: [Int] = []

    init(
        estimatedCount: Int32,
        returnedProcessIDs: [pid_t],
        sizingErrno: Int32 = 0
    ) {
        self.estimatedCount = estimatedCount
        self.returnedProcessIDs = returnedProcessIDs
        self.sizingErrno = sizingErrno
    }

    var requestedCapacities: [Int] {
        lock.withLock { capacities }
    }

    func call(
        processGroupID _: pid_t,
        buffer: UnsafeMutableRawPointer?,
        bufferSize: Int32
    ) -> Int32 {
        guard let buffer else {
            errno = sizingErrno
            return estimatedCount
        }

        let capacity = Int(bufferSize) / MemoryLayout<pid_t>.stride
        lock.withLock { capacities.append(capacity) }
        let count = min(capacity, returnedProcessIDs.count)
        let typedBuffer = buffer.bindMemory(to: pid_t.self, capacity: capacity)
        for index in 0..<count {
            typedBuffer[index] = returnedProcessIDs[index]
        }
        return Int32(count)
    }
}

private final class ProcessLeaseEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}
