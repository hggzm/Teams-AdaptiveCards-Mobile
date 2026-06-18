import Foundation
import Testing
@testable import SwiftCIKit

@Suite("JenkinsfileImporter")
struct JenkinsfileImporterTests {

    @Test("minimal declarative pipeline becomes 1 step")
    func minimal() throws {
        let src = """
        pipeline {
            agent any
            stages {
                stage('Build') {
                    steps {
                        sh 'echo hello'
                    }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src, defaultName: "Demo")
        #expect(r.pipeline.name == "Demo")
        #expect(r.pipeline.steps.count == 1)
        #expect(r.pipeline.steps[0].name == "Build")
        #expect(r.pipeline.steps[0].run == "echo hello")
    }

    @Test("multiple stages each become their own step")
    func multiStage() throws {
        let src = """
        pipeline {
            agent any
            stages {
                stage('A') { steps { sh 'echo A' } }
                stage('B') { steps { sh 'echo B' } }
                stage('C') { steps { sh 'echo C' } }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.pipeline.steps.map(\.name) == ["A", "B", "C"])
        #expect(r.pipeline.steps[1].run == "echo B")
    }

    @Test("multiple sh lines in one stage are joined with newlines")
    func multipleShLines() throws {
        let src = """
        pipeline {
            stages {
                stage('X') {
                    steps {
                        sh 'echo one'
                        sh 'echo two'
                        sh 'echo three'
                    }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.pipeline.steps[0].run == "echo one\necho two\necho three")
    }

    @Test("top-level + per-stage environment merge")
    func envMerge() throws {
        let src = """
        pipeline {
            environment {
                GLOBAL = 'one'
                SHARED = 'top'
            }
            stages {
                stage('Build') {
                    environment {
                        STAGE = 'two'
                        SHARED = 'stage'
                    }
                    steps {
                        sh 'echo hi'
                    }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        let env = r.pipeline.steps[0].env
        #expect(env["GLOBAL"] == "one")
        #expect(env["STAGE"] == "two")
        #expect(env["SHARED"] == "stage")          // per-stage overrides
    }

    @Test("archiveArtifacts collects pattern")
    func archiveArtifacts() throws {
        let src = """
        pipeline {
            stages {
                stage('Pack') {
                    steps {
                        sh 'mkdir out'
                        archiveArtifacts artifacts: 'out/*.zip', allowEmptyArchive: true
                    }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.pipeline.steps[0].artifacts == ["out/*.zip"])
    }

    @Test("post failure with httpRequest becomes notify on: .failed")
    func postFailureHttpRequest() throws {
        let src = """
        pipeline {
            stages {
                stage('B') { steps { sh 'true' } }
            }
            post {
                failure {
                    httpRequest url: 'https://example.com/hook', httpMode: 'POST'
                }
                success {
                    httpRequest 'https://example.com/ok'
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.pipeline.notify.count == 2)
        let urls = r.pipeline.notify.map(\.url)
        #expect(urls.contains("https://example.com/hook"))
        #expect(urls.contains("https://example.com/ok"))
        let failure = r.pipeline.notify.first { $0.url.hasSuffix("/hook") }
        #expect(failure?.on == .failed)
        let success = r.pipeline.notify.first { $0.url.hasSuffix("/ok") }
        #expect(success?.on == .passed)
    }

    @Test("triple-quoted shell strings preserve newlines")
    func tripleQuoted() throws {
        let src = """
        pipeline {
            stages {
                stage('Multi') {
                    steps {
                        sh '''
                          echo first
                          echo second
                        '''
                    }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.pipeline.steps[0].run.contains("echo first"))
        #expect(r.pipeline.steps[0].run.contains("echo second"))
    }

    @Test("scripted Jenkinsfile (node block) is rejected")
    func scripted() throws {
        let src = """
        node('master') {
            stage('Build') {
                sh 'echo hi'
            }
        }
        """
        do {
            _ = try JenkinsfileImporter.parse(src)
            Issue.record("expected scripted-Jenkinsfile rejection")
        } catch JenkinsfileImporter.ParseError.scripted {
            // expected
        }
    }

    @Test("unknown step generates a warning, doesn't fail")
    func unknownStepWarns() throws {
        let src = """
        pipeline {
            stages {
                stage('X') {
                    steps {
                        sh 'echo ok'
                        nonsenseStep 'whatever', foo: 'bar'
                    }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.pipeline.steps[0].run == "echo ok")
        #expect(r.warnings.contains { $0.contains("nonsenseStep") })
    }

    @Test("echo statement translates to echo command")
    func echo() throws {
        let src = """
        pipeline {
            stages {
                stage('Say') {
                    steps {
                        echo 'hi there'
                    }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.pipeline.steps[0].run == "echo 'hi there'")
    }

    @Test("comments are ignored")
    func comments() throws {
        let src = """
        // top-level comment
        pipeline {
            /* multi
               line
               comment */
            stages {
                // before stage
                stage('B') {  // inline
                    steps {
                        sh 'echo c'  // tail
                    }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.pipeline.steps.count == 1)
        #expect(r.pipeline.steps[0].run == "echo c")
    }

    @Test("missing pipeline block throws noPipelineBlock")
    func noPipelineBlock() throws {
        let src = "stages { stage('x') { sh 'echo' } }"
        do {
            _ = try JenkinsfileImporter.parse(src)
            Issue.record("expected noPipelineBlock")
        } catch JenkinsfileImporter.ParseError.scripted {
            // 'stage' top-level is rejected as scripted — acceptable
        } catch JenkinsfileImporter.ParseError.noPipelineBlock {
            // also acceptable
        }
    }

    // ──────────────────────────────────────────────────────────────
    // Phase 24: parameters { ... }
    // ──────────────────────────────────────────────────────────────

    @Test("parameters block translates string/booleanParam/choice defaults to env")
    func parametersToEnv() throws {
        let src = """
        pipeline {
            parameters {
                string(name: 'GREETING', defaultValue: 'Hello', description: 'g')
                booleanParam(name: 'VERBOSE', defaultValue: true)
                choice(name: 'TARGET', choices: ['debug', 'release'])
            }
            stages {
                stage('Build') {
                    steps {
                        sh 'echo hi'
                    }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        let env = r.pipeline.steps[0].env
        #expect(env["GREETING"] == "Hello")
        #expect(env["VERBOSE"] == "true")
        #expect(env["TARGET"] == "debug")
    }

    @Test("parameters: explicit env overrides parameter default")
    func parametersOverriddenByEnv() throws {
        let src = """
        pipeline {
            parameters {
                string(name: 'GREETING', defaultValue: 'Hello')
            }
            environment {
                GREETING = 'Howdy'
            }
            stages {
                stage('Build') {
                    steps { sh 'echo hi' }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.pipeline.steps[0].env["GREETING"] == "Howdy")
    }

    @Test("unknown parameter kind warns but does not fail")
    func parametersUnknownKind() throws {
        let src = """
        pipeline {
            parameters {
                password(name: 'SECRET')
                string(name: 'OK', defaultValue: 'yes')
            }
            stages {
                stage('Build') { steps { sh 'echo hi' } }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.pipeline.steps[0].env["OK"] == "yes")
        #expect(r.pipeline.steps[0].env["SECRET"] == nil)
        #expect(r.warnings.contains { $0.contains("password") })
    }

    @Test("booleanParam defaultValue false renders as \"false\"")
    func parametersBooleanFalse() throws {
        let src = """
        pipeline {
            parameters {
                booleanParam(name: 'FLAG', defaultValue: false)
            }
            stages {
                stage('Build') { steps { sh 'echo hi' } }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.pipeline.steps[0].env["FLAG"] == "false")
    }

    // ──────────────────────────────────────────────────────────────
    // Phase 31a: examples/jenkins-interop/shared-pipeline.Jenkinsfile
    // must import with zero warnings on every commit. This is the
    // automated guarantee behind the README's claim that that file
    // is genuinely cross-engine.
    // ──────────────────────────────────────────────────────────────
    @Test("examples/jenkins-interop/shared-pipeline.Jenkinsfile imports with zero warnings")
    func sharedInteropPipelineCleanImport() throws {
        // The shared-pipeline example must import cleanly forever.
        // We embed the canonical source here so the test stays
        // hermetic, then in `sharedInteropPipelineMatchesEmbeddedSource`
        // we cross-check that the on-disk file has not drifted.
        let src = Self.sharedInteropEmbeddedSource

        let r = try JenkinsfileImporter.parse(src, defaultName: "Shared")
        let joined = r.warnings.joined(separator: "; ")
        #expect(r.warnings.isEmpty, "unexpected warnings: \(joined)")
        // 4 stages → 4 steps.
        #expect(r.pipeline.steps.count == 4)
        // parameters{} defaults flowed into the pipeline env, then
        // got merged into each step's env.
        #expect(r.pipeline.steps[0].env["GREETING"] == "hello")
        #expect(r.pipeline.steps[0].env["TARGET"] == "world")
        #expect(r.pipeline.steps[0].env["BUILD_LABEL"] == "shared")
        // Per-stage env override on the third stage wins over the
        // top-level default.
        #expect(r.pipeline.steps[2].env["GREETING"] == "salutations")
        // archiveArtifacts pattern landed on the right step.
        #expect(r.pipeline.steps[1].artifacts.contains("out/greeting.txt"))
    }

    @Test("examples/jenkins-interop/shared-pipeline.Jenkinsfile on disk matches embedded source")
    func sharedInteropPipelineMatchesEmbeddedSource() throws {
        // Locate the example file. `swift test` runs with cwd =
        // package root; #filePath gives the absolute test source
        // location as a fallback for editor-driven runs.
        let fm = FileManager.default
        let relative = "examples/jenkins-interop/shared-pipeline.Jenkinsfile"
        let candidates: [URL] = [
            URL(fileURLWithPath: relative, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("examples")
                .appendingPathComponent("jenkins-interop")
                .appendingPathComponent("shared-pipeline.Jenkinsfile"),
        ]
        guard let sample = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            Issue.record("could not locate shared-pipeline.Jenkinsfile; tried: \(candidates.map(\.path))")
            return
        }
        let onDisk = try String(contentsOf: sample, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let embedded = Self.sharedInteropEmbeddedSource
            .replacingOccurrences(of: "\r\n", with: "\n")
        #expect(onDisk == embedded,
                "examples/jenkins-interop/shared-pipeline.Jenkinsfile drifted from embedded source in JenkinsfileImporterTests.swift; update the embedded copy")
    }

    /// Canonical source for `examples/jenkins-interop/shared-pipeline.Jenkinsfile`.
    /// Keep byte-identical to the on-disk file.
    static let sharedInteropEmbeddedSource: String = """
    // Mode 3: a single Jenkinsfile that runs identically on both
    // engines. Restricted to the declarative subset that Jenkins's
    // declarative parser AND swiftci's `JenkinsfileImporter` both
    // understand. Run through swiftci first with
    //   swift run swiftci validate examples/jenkins-interop/shared-pipeline.Jenkinsfile
    // to confirm there are zero translation warnings before pointing
    // Jenkins at it.

    pipeline {
        agent any

        parameters {
            string(name: 'GREETING',     defaultValue: 'hello',  description: 'Salutation to print')
            string(name: 'TARGET',       defaultValue: 'world',  description: 'Who to greet')
            string(name: 'BUILD_LABEL',  defaultValue: 'shared', description: 'Free-form label baked into artifacts')
        }

        environment {
            // Both engines flow `parameters {}` defaults into the env so
            // `$GREETING` etc. work uniformly inside `sh` blocks.
            BANNER = "[${BUILD_LABEL}]"
        }

        stages {
            stage('Greet') {
                steps {
                    sh 'echo "$BANNER $GREETING, $TARGET"'
                }
            }

            stage('Produce artifact') {
                steps {
                    sh '''
                        mkdir -p out
                        printf '%s %s, %s\\\\n' "$BANNER" "$GREETING" "$TARGET" > out/greeting.txt
                    '''
                    archiveArtifacts artifacts: 'out/greeting.txt'
                }
            }

            stage('Per-stage env override') {
                environment {
                    GREETING = 'salutations'
                }
                steps {
                    // Demonstrates that per-stage env wins over top-level
                    // env on both engines.
                    sh 'echo "$BANNER $GREETING, $TARGET (overridden in stage)"'
                }
            }

            stage('withEnv inline') {
                steps {
                    withEnv(['MOOD=cheerful']) {
                        sh 'echo "$BANNER ($MOOD) $GREETING, $TARGET"'
                    }
                }
            }
        }

        // NOTE: a top-level `post { ... }` block is intentionally
        // omitted. Jenkins's declarative `post { always { sh '...' } }`
        // and swiftci's `notify:` block do not fully overlap — swiftci's
        // importer only translates `httpRequest` calls inside `post {}`,
        // dropping `sh` actions with a warning. To keep this sample
        // bit-for-bit identical on both engines, do final work inside
        // the last stage rather than relying on `post`. See
        // examples/jenkins-interop/jenkins-to-swiftci.Jenkinsfile for
        // the cross-engine notification pattern.
    }

    """

    // ──────────────────────────────────────────────────────────────
    // Phase 32: when {} stage gating
    // ──────────────────────────────────────────────────────────────

    @Test("when { branch 'main' } parses to .branch condition")
    func whenBranchSimple() throws {
        let src = """
        pipeline {
            stages {
                stage('Deploy') {
                    when { branch 'main' }
                    steps { sh 'echo deploying' }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.warnings.isEmpty)
        #expect(r.pipeline.steps.count == 1)
        #expect(r.pipeline.steps[0].condition == .branch("main"))
    }

    @Test("when { environment name: 'X', value: 'Y' } parses to .environment")
    func whenEnvironmentPredicate() throws {
        let src = """
        pipeline {
            stages {
                stage('Deploy') {
                    when { environment name: 'DEPLOY', value: 'yes' }
                    steps { sh 'echo go' }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.warnings.isEmpty)
        #expect(r.pipeline.steps[0].condition
                == .environment(name: "DEPLOY", value: "yes"))
    }

    @Test("when { not { branch 'main' } } parses to .not(.branch)")
    func whenNotBranch() throws {
        let src = """
        pipeline {
            stages {
                stage('PR') {
                    when { not { branch 'main' } }
                    steps { sh 'echo pr-only' }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.warnings.isEmpty)
        #expect(r.pipeline.steps[0].condition
                == .not(.branch("main")))
    }

    @Test("when { allOf { … } } and anyOf { … } compose")
    func whenAllOfAnyOf() throws {
        let src = """
        pipeline {
            stages {
                stage('Release') {
                    when {
                        allOf {
                            branch 'release/*'
                            environment name: 'PUBLISH', value: 'true'
                        }
                    }
                    steps { sh 'echo release' }
                }
                stage('Hotfix') {
                    when {
                        anyOf {
                            branch 'main'
                            branch 'hotfix/*'
                        }
                    }
                    steps { sh 'echo hotfix' }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.warnings.isEmpty)
        #expect(r.pipeline.steps[0].condition == .allOf([
            .branch("release/*"),
            .environment(name: "PUBLISH", value: "true"),
        ]))
        #expect(r.pipeline.steps[1].condition == .anyOf([
            .branch("main"),
            .branch("hotfix/*"),
        ]))
    }

    @Test("when { expression { … } } warns and drops the expression")
    func whenExpressionDropped() throws {
        let src = """
        pipeline {
            stages {
                stage('X') {
                    when {
                        expression { return params.SHOULD_RUN == 'yes' }
                    }
                    steps { sh 'echo x' }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.warnings.contains { $0.contains("expression") })
        // Predicate had nothing translatable → no condition, but
        // step still imported.
        #expect(r.pipeline.steps[0].condition == nil)
    }

    @Test("StepCondition.evaluate handles branch glob and env equality")
    func stepConditionEvaluate() {
        // .branch with exact match
        #expect(Pipeline.StepCondition.branch("main")
                .evaluate(env: ["BRANCH_NAME": "main"]))
        #expect(!Pipeline.StepCondition.branch("main")
                .evaluate(env: ["BRANCH_NAME": "develop"]))
        // .branch with glob suffix
        #expect(Pipeline.StepCondition.branch("feature/*")
                .evaluate(env: ["BRANCH_NAME": "feature/login"]))
        #expect(!Pipeline.StepCondition.branch("feature/*")
                .evaluate(env: ["BRANCH_NAME": "main"]))
        // .branch falls back to GIT_BRANCH
        #expect(Pipeline.StepCondition.branch("main")
                .evaluate(env: ["GIT_BRANCH": "main"]))
        // .environment exact
        #expect(Pipeline.StepCondition.environment(name: "DEPLOY", value: "yes")
                .evaluate(env: ["DEPLOY": "yes"]))
        #expect(!Pipeline.StepCondition.environment(name: "DEPLOY", value: "yes")
                .evaluate(env: ["DEPLOY": "no"]))
        // .not / .allOf / .anyOf composition
        #expect(Pipeline.StepCondition.not(.branch("main"))
                .evaluate(env: ["BRANCH_NAME": "develop"]))
        #expect(Pipeline.StepCondition.allOf([
            .branch("main"),
            .environment(name: "OK", value: "1"),
        ]).evaluate(env: ["BRANCH_NAME": "main", "OK": "1"]))
        #expect(!Pipeline.StepCondition.allOf([
            .branch("main"),
            .environment(name: "OK", value: "1"),
        ]).evaluate(env: ["BRANCH_NAME": "main", "OK": "0"]))
        #expect(Pipeline.StepCondition.anyOf([
            .branch("main"),
            .branch("release/*"),
        ]).evaluate(env: ["BRANCH_NAME": "release/1.0"]))
    }

    @Test("StepCondition Codable round-trip")
    func stepConditionCodable() throws {
        let cases: [Pipeline.StepCondition] = [
            .branch("main"),
            .environment(name: "X", value: "Y"),
            .not(.branch("dev")),
            .allOf([.branch("a"), .environment(name: "B", value: "C")]),
            .anyOf([.branch("x"), .branch("y")]),
        ]
        for c in cases {
            let data = try JSONEncoder().encode(c)
            let back = try JSONDecoder().decode(Pipeline.StepCondition.self, from: data)
            #expect(back == c)
        }
    }
}

@Suite("JenkinsfileImporter parallel (Phase 36)")
struct JenkinsfileImporterParallelTests {
    @Test("parallel block becomes a single Step with one branch per inner stage")
    func parallelBecomesGroup() throws {
        let src = """
        pipeline {
            stages {
                stage('Fan') {
                    parallel {
                        stage('A') { steps { sh 'echo A' } }
                        stage('B') { steps { sh 'echo B' } }
                    }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.pipeline.steps.count == 1)
        let s = r.pipeline.steps[0]
        #expect(s.parallel != nil)
        #expect(s.parallel?.count == 2)
        #expect(s.parallel?.map(\.name) == ["A", "B"])
        // Each branch wraps the inner stage's converted Step(s).
        #expect(s.parallel?[0].steps.first?.run == "echo A")
        #expect(s.parallel?[1].steps.first?.run == "echo B")
        // No flatten-warning anymore (Phase 36 runs branches concurrently).
        #expect(!r.warnings.contains { $0.contains("flattened to sequential") })
    }
}

@Suite("JenkinsfileImporter withCredentials (Phase 37)")
struct JenkinsfileImporterCredentialsTests {
    @Test("withCredentials([string(...)]) populates Step.credentials")
    func basicStringBinding() throws {
        let src = """
        pipeline {
            stages {
                stage('Deploy') {
                    steps {
                        withCredentials([string(credentialsId: 'deploy-key', variable: 'KEY')]) {
                            sh 'echo $KEY'
                        }
                    }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.pipeline.steps.count == 1)
        let s = r.pipeline.steps[0]
        #expect(s.credentials.count == 1)
        #expect(s.credentials[0].credentialsId == "deploy-key")
        #expect(s.credentials[0].variable == "KEY")
        #expect(s.run == "echo $KEY")
    }

    @Test("multiple string bindings in one withCredentials")
    func multipleBindings() throws {
        let src = """
        pipeline {
            stages {
                stage('S') {
                    steps {
                        withCredentials([
                            string(credentialsId: 'a', variable: 'A'),
                            string(credentialsId: 'b', variable: 'B')
                        ]) {
                            sh 'echo $A $B'
                        }
                    }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.pipeline.steps[0].credentials.map(\.variable) == ["A", "B"])
    }

    @Test("unsupported binding shapes warn but do not crash the import")
    func unsupportedBindingWarns() throws {
        let src = """
        pipeline {
            stages {
                stage('S') {
                    steps {
                        withCredentials([
                            usernamePassword(credentialsId: 'u', usernameVariable: 'U', passwordVariable: 'P'),
                            string(credentialsId: 'tok', variable: 'TOK')
                        ]) {
                            sh 'echo hi'
                        }
                    }
                }
            }
        }
        """
        let r = try JenkinsfileImporter.parse(src)
        #expect(r.pipeline.steps[0].credentials.map(\.variable) == ["TOK"])
        #expect(r.warnings.contains { $0.contains("usernamePassword") })
    }
}



