import Foundation
import Testing
@testable import SwiftCIKit

@Suite("BuildLogBroadcaster")
struct BuildLogBroadcasterTests {
    @Test("subscribers receive chunks published after subscribe")
    func basicPublish() async throws {
        let broadcaster = BuildLogBroadcaster()
        let stream = await broadcaster.subscribe(jobID: "job-1", number: 1)

        // Publishing must be done from a separate task so the consumer
        // can start awaiting before the chunks land.
        Task {
            await broadcaster.publish(jobID: "job-1", number: 1, "hello\n")
            await broadcaster.publish(jobID: "job-1", number: 1, "world\n")
            await broadcaster.finish(jobID: "job-1", number: 1)
        }

        var received: [String] = []
        for await chunk in stream {
            received.append(chunk)
        }
        #expect(received == ["hello\n", "world\n"])
    }

    @Test("subscribers don't see chunks for other (jobID, number) pairs")
    func isolation() async throws {
        let broadcaster = BuildLogBroadcaster()
        let stream = await broadcaster.subscribe(jobID: "job-A", number: 1)
        Task {
            await broadcaster.publish(jobID: "job-B", number: 1, "B1\n")
            await broadcaster.publish(jobID: "job-A", number: 2, "A2\n")
            await broadcaster.publish(jobID: "job-A", number: 1, "A1\n")
            await broadcaster.finish(jobID: "job-A", number: 1)
        }
        var received: [String] = []
        for await chunk in stream { received.append(chunk) }
        #expect(received == ["A1\n"])
    }

    @Test("multiple subscribers all receive each chunk")
    func fanOut() async throws {
        let broadcaster = BuildLogBroadcaster()
        let s1 = await broadcaster.subscribe(jobID: "j", number: 1)
        let s2 = await broadcaster.subscribe(jobID: "j", number: 1)
        let s3 = await broadcaster.subscribe(jobID: "j", number: 1)
        Task {
            await broadcaster.publish(jobID: "j", number: 1, "x\n")
            await broadcaster.publish(jobID: "j", number: 1, "y\n")
            await broadcaster.finish(jobID: "j", number: 1)
        }
        func drain(_ s: AsyncStream<String>) async -> [String] {
            var out: [String] = []
            for await c in s { out.append(c) }
            return out
        }
        async let r1 = drain(s1)
        async let r2 = drain(s2)
        async let r3 = drain(s3)
        let (a, b, c) = await (r1, r2, r3)
        #expect(a == ["x\n", "y\n"])
        #expect(b == ["x\n", "y\n"])
        #expect(c == ["x\n", "y\n"])
    }

    @Test("subscribing to an already-finished build yields an empty stream")
    func lateSubscriber() async throws {
        let broadcaster = BuildLogBroadcaster()
        await broadcaster.publish(jobID: "j", number: 1, "ignored\n")
        await broadcaster.finish(jobID: "j", number: 1)
        let stream = await broadcaster.subscribe(jobID: "j", number: 1)
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
        #expect(await broadcaster.isFinished(jobID: "j", number: 1))
    }

    @Test("BuildExecutor publishes live chunks while running")
    func executorPublishesLive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftci-bcast-\(UUID().uuidString)", isDirectory: true)
        let store = JobStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobID = try store.createJob(from: Pipeline(
            name: "BcastEcho",
            steps: [.init(name: "Hi", run: "echo hello-broadcast")]
        ))
        let executor = BuildExecutor(store: store)
        let stream = await executor.broadcaster.subscribe(jobID: jobID, number: 1)
        await executor.start()
        _ = try await executor.enqueue(jobID: jobID)

        var accumulated = ""
        for await chunk in stream {
            accumulated += chunk
        }
        await executor.stop()

        #expect(accumulated.contains("hello-broadcast"))
        #expect(accumulated.contains("=== build #1"))
        #expect(accumulated.contains("finished: passed"))
    }
}
