//
//  KeyedExecutorTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/21/26.
//

import Testing
import IrisCommon
import Foundation

@Suite struct KeyedExecutorTests {

    /// Records the relative interleaving of operations so tests can assert
    /// whether work ran serially or concurrently.
    private actor Recorder {
        private(set) var log: [String] = []
        private var active = 0
        private(set) var maxConcurrent = 0

        func enter() {
            active += 1
            maxConcurrent = max(maxConcurrent, active)
        }

        func leave() {
            active -= 1
        }

        func append(_ entry: String) {
            log.append(entry)
        }
    }

    /// A one-shot signal that can be awaited before it is fired and resolves
    /// immediately afterwards. Used to coordinate ordering between operations.
    private actor Signal {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var fired = false

        func wait() async {
            if fired { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func fire() {
            guard !fired else { return }
            fired = true
            for continuation in continuations {
                continuation.resume()
            }
            continuations.removeAll()
        }
    }

    /// Operations submitted under the same key must run one at a time, never overlapping.
    @Test func sameKeyRunsSerially() async throws {
        let executor: KeyedExecutor<UUID> = KeyedExecutor()
        let recorder = Recorder()
        let key = UUID()

        var tasks: [Task<Int, Error>] = []
        for index in 0..<5 {
            let task = await executor.submit(key) {
                await recorder.enter()
                await recorder.append("start-\(index)")
                // Yield/sleep so that overlapping work would be observable.
                try await Task.sleep(for: .milliseconds(10))
                await recorder.append("end-\(index)")
                await recorder.leave()
                return index
            }
            tasks.append(task)
        }

        for task in tasks {
            _ = try await task.value
        }

        let maxConcurrent = await recorder.maxConcurrent
        #expect(maxConcurrent == 1, "Operations sharing a key must never run concurrently.")

        let log = await recorder.log
        let expected = (0..<5).flatMap { ["start-\($0)", "end-\($0)"] }
        #expect(log == expected, "Operations sharing a key must run in submission (FIFO) order without interleaving.")
    }

    /// Operations submitted under different keys must be free to run concurrently.
    @Test func differentKeysRunConcurrently() async throws {
        let executor: KeyedExecutor<UUID> = KeyedExecutor()
        let keyA = UUID()
        let keyB = UUID()
        let bIsRunning = Signal()

        // Operation A starts first but cannot finish until operation B (a different
        // key) has begun. If different keys were serialized this would deadlock.
        let taskA = await executor.submit(keyA) {
            await bIsRunning.wait()
            return "A"
        }
        let taskB = await executor.submit(keyB) {
            await bIsRunning.fire()
            return "B"
        }

        // Guard against a hang if the behavior regresses to global serialization.
        let timeout = Task<Void, Error> {
            try await Task.sleep(for: .seconds(5))
            throw CancellationError()
        }
        defer { timeout.cancel() }

        let resultA = try await taskA.value
        let resultB = try await taskB.value
        #expect(resultA == "A")
        #expect(resultB == "B")
    }

    /// `run` should return the operation's value, and `submit` should hand back an awaitable task.
    @Test func returnsOperationValue() async throws {
        let executor: KeyedExecutor<UUID> = KeyedExecutor()
        let key = UUID()

        let runResult = try await executor.run(key) { 42 }
        #expect(runResult == 42)

        let submitted = await executor.submit(key) { "hello" }
        let submitResult = try await submitted.value
        #expect(submitResult == "hello")
    }

    private struct SampleError: Error, Equatable {}

    /// A thrown error must surface to the caller of that specific operation.
    @Test func errorPropagatesToCaller() async throws {
        let executor: KeyedExecutor<UUID> = KeyedExecutor()
        let key = UUID()

        await #expect(throws: SampleError.self) {
            try await executor.run(key) {
                throw SampleError()
            }
        }
    }

    /// A failing operation must not break the chain: later operations on the same key still run.
    @Test func failedOperationDoesNotBreakChain() async throws {
        let executor: KeyedExecutor<UUID> = KeyedExecutor()
        let key = UUID()

        let failing = await executor.submit(key) { () throws -> Int in
            throw SampleError()
        }
        let succeeding = await executor.submit(key) { 7 }

        await #expect(throws: SampleError.self) {
            _ = try await failing.value
        }

        let result = try await succeeding.value
        #expect(result == 7, "An earlier failure must not prevent later operations on the same key from running.")
    }

    /// A long-running operation on one key must not delay an operation on another key.
    @Test func slowKeyDoesNotBlockOtherKeys() async throws {
        let executor: KeyedExecutor<UUID> = KeyedExecutor()
        let recorder = Recorder()
        let slowKey = UUID()
        let fastKey = UUID()

        let slow = await executor.submit(slowKey) {
            try await Task.sleep(for: .milliseconds(200))
            await recorder.append("slow")
            return "slow"
        }
        let fast = await executor.submit(fastKey) {
            await recorder.append("fast")
            return "fast"
        }

        _ = try await fast.value
        _ = try await slow.value

        let log = await recorder.log
        #expect(log.first == "fast", "A fast operation on its own key should complete before a slow operation on a different key.")
    }
}
