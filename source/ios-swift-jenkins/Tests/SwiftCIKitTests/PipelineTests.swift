import Foundation
import Testing
@testable import SwiftCIKit

@Suite("Pipeline YAML")
struct PipelineTests {
    @Test("decodes a minimal pipeline")
    func decodeMinimal() throws {
        let yaml = """
        name: Build & Test
        steps:
          - name: Compile
            run: swift build
          - name: Test
            run: swift test --parallel
        """
        let pipeline = try Pipeline.decode(yaml: yaml)
        #expect(pipeline.name == "Build & Test")
        #expect(pipeline.steps.count == 2)
        #expect(pipeline.steps[0].name == "Compile")
        #expect(pipeline.steps[0].run == "swift build")
        #expect(pipeline.steps[1].run == "swift test --parallel")
    }

    @Test("rejects an empty document")
    func emptyDocument() {
        #expect(throws: PipelineError.empty) {
            try Pipeline.decode(yaml: "   \n\t  \n")
        }
    }

    @Test("round-trips through encodeYAML/decode")
    func roundTrip() throws {
        let original = Pipeline(
            name: "Round Trip",
            steps: [
                .init(name: "One",   run: "echo one"),
                .init(name: "Two",   run: "echo two"),
                .init(name: "Three", run: "echo three"),
            ]
        )
        let yaml = try original.encodeYAML()
        let decoded = try Pipeline.decode(yaml: yaml)
        #expect(decoded == original)
    }

    @Test("surfaces malformed YAML as a thrown error")
    func malformedYAML() {
        #expect(throws: (any Error).self) {
            try Pipeline.decode(yaml: "name: [unterminated")
        }
    }

    @Test("agentLabels defaults to empty when omitted")
    func agentLabelsDefault() throws {
        let yaml = """
        name: NoLabels
        steps:
          - name: S
            run: echo hi
        """
        let pipeline = try Pipeline.decode(yaml: yaml)
        #expect(pipeline.agentLabels.isEmpty)
    }

    @Test("agentLabels round-trips through YAML")
    func agentLabelsRoundTrip() throws {
        let original = Pipeline(
            name: "Labeled",
            steps: [.init(name: "S", run: "echo hi")],
            agentLabels: ["windows", "gpu"]
        )
        let yaml = try original.encodeYAML()
        let decoded = try Pipeline.decode(yaml: yaml)
        #expect(decoded.agentLabels == ["windows", "gpu"])
        #expect(decoded == original)
    }

    @Test("agentLabels decodes from explicit YAML list")
    func agentLabelsExplicit() throws {
        let yaml = """
        name: Labeled
        agentLabels: [linux, arm64]
        steps:
          - name: S
            run: echo hi
        """
        let pipeline = try Pipeline.decode(yaml: yaml)
        #expect(pipeline.agentLabels == ["linux", "arm64"])
    }
}

@Suite("Pipeline parallel (Phase 36)")
struct PipelineParallelTests {
    @Test("step decodes parallel branches from YAML")
    func decodesParallel() throws {
        let yaml = """
        name: Fanout
        steps:
          - name: fan
            parallel:
              - name: a
                steps:
                  - name: a1
                    run: echo a
              - name: b
                steps:
                  - name: b1
                    run: echo b
        """
        let p = try Pipeline.decode(yaml: yaml)
        #expect(p.steps.count == 1)
        let s = p.steps[0]
        #expect(s.parallel?.count == 2)
        #expect(s.parallel?[0].name == "a")
        #expect(s.parallel?[1].steps.first?.run == "echo b")
        #expect(s.run.isEmpty)
    }

    @Test("encode + decode round-trips a parallel step")
    func roundTripParallel() throws {
        let original = Pipeline(
            name: "Fan",
            steps: [
                .init(
                    name: "fan",
                    run: "",
                    parallel: [
                        .init(name: "a", steps: [.init(name: "a1", run: "echo a")]),
                        .init(name: "b", steps: [.init(name: "b1", run: "echo b")]),
                    ]),
            ])
        let yaml = try original.encodeYAML()
        let decoded = try Pipeline.decode(yaml: yaml)
        #expect(decoded == original)
    }

    @Test("rejects a step that sets both run: and parallel:")
    func rejectsBoth() {
        let yaml = """
        name: Bad
        steps:
          - name: x
            run: echo hi
            parallel:
              - name: a
                steps:
                  - name: a1
                    run: echo a
        """
        #expect(throws: (any Error).self) {
            _ = try Pipeline.decode(yaml: yaml)
        }
    }

    @Test("rejects a step that sets neither run: nor parallel:")
    func rejectsNeither() {
        let yaml = """
        name: Bad
        steps:
          - name: x
        """
        #expect(throws: (any Error).self) {
            _ = try Pipeline.decode(yaml: yaml)
        }
    }

    @Test("rejects an empty parallel:")
    func rejectsEmptyParallel() {
        let yaml = """
        name: Bad
        steps:
          - name: x
            parallel: []
        """
        #expect(throws: (any Error).self) {
            _ = try Pipeline.decode(yaml: yaml)
        }
    }

    @Test("rejects nested parallel inside a branch")
    func rejectsNested() {
        let yaml = """
        name: Bad
        steps:
          - name: outer
            parallel:
              - name: a
                steps:
                  - name: inner
                    parallel:
                      - name: b
                        steps:
                          - name: b1
                            run: echo b
        """
        #expect(throws: (any Error).self) {
            _ = try Pipeline.decode(yaml: yaml)
        }
    }
}
