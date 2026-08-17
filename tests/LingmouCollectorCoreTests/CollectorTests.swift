import Foundation
import XCTest

@testable import LingmouCollectorCore

final class CollectorTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func touch(_ url: URL, at timestamp: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: timestamp)],
            ofItemAtPath: url.path
        )
    }

    private func processSupport(_ names: [String]) -> ProcessSupport {
        ProcessSupport { executable, arguments, _ in
            guard executable == "/bin/ps", arguments.contains("args=") else { return "" }
            return names.map { "/usr/local/bin/\($0)" }.joined(separator: "\n") + "\n"
        }
    }

    func testSwiftBarEscapesUntrustedTitles() {
        let collector = LingmouCollector()
        let tool = ToolStatus(
            key: "test",
            letter: "T",
            name: "测试",
            state: "busy",
            busyItems: [BusyItem(id: "1", title: "正常| bash=危险\n下一行")],
            detail: "1 个任务",
            latestTitle: nil,
            latestAge: nil,
            quota: nil
        )
        let output = collector.renderSwiftBar(StatusData(updatedAt: "", tools: [tool], usage: nil))
        XCTAssertTrue(output.contains("正常¦ bash=危险 下一行 | size=11"))
        XCTAssertFalse(output.contains("正常| bash="))
    }

    func testOnlineQuotaDefaultsOn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let collector = LingmouCollector(
            environment: CollectorEnvironment(homeDirectory: directory.path, now: 1))
        XCTAssertTrue(collector.settings.onlineQuota)
    }

    func testJSONContractUsesSnakeCase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let collector = LingmouCollector(
            environment: CollectorEnvironment(homeDirectory: directory.path, now: 1))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: collector.jsonData()) as? [String: Any])
        XCTAssertNotNil(object["updated_at"])
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 7)
        XCTAssertNotNil(tools[0]["busy_count"])
    }

    func testPrivateJSONPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cache.json").path
        try FileSupport().writePrivateJSON(["value": 1], to: path)
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)
    }

    func testUsageParsersMatchExistingTokenRules() throws {
        let codex = try XCTUnwrap(
            UsageParsers.codex(
                """
                {"timestamp":"2026-08-13T01:02:03Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":30,"cached_input_tokens":12,"output_tokens":7}}}}
                """))
        XCTAssertEqual(codex.input, 18)
        XCTAssertEqual(codex.output, 7)
        XCTAssertEqual(codex.cache, 12)

        let kimi = try XCTUnwrap(
            UsageParsers.kimi(
                """
                {"type":"usage.record","time":10000,"usage":{"inputOther":3,"output":4,"inputCacheRead":5}}
                """))
        XCTAssertEqual(kimi, ParsedUsage(timestamp: 10, input: 3, output: 4, cache: 5))

        let claude = try XCTUnwrap(
            UsageParsers.claude(
                """
                {"timestamp":"2026-08-13T01:02:03Z","message":{"usage":{"input_tokens":8,"output_tokens":9,"cache_read_input_tokens":10}}}
                """))
        XCTAssertEqual(claude.input, 8)
        XCTAssertEqual(claude.output, 9)
        XCTAssertEqual(claude.cache, 10)

        let zcode = try XCTUnwrap(
            UsageParsers.zcode(
                """
                {"completedAt":"2026-08-13T01:02:03Z","response":{"usage":{"inputTokens":20,"outputTokens":6,"cacheReadTokens":11}}}
                """))
        XCTAssertEqual(zcode.input, 9)
        XCTAssertEqual(zcode.output, 6)
        XCTAssertEqual(zcode.cache, 11)
    }

    func testExactDepthDoesNotIncludeNestedSubagentLogs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let direct = root.appendingPathComponent("project/session.jsonl")
        let nested = root.appendingPathComponent("project/session/subagents/agent.jsonl")
        try write("{}\n", to: direct)
        try write("{}\n", to: nested)
        let found = FileSupport().files(atDepth: 2, under: root.path) { $0.hasSuffix(".jsonl") }
        XCTAssertEqual(found, [direct.path])
    }

    func testCodexCollectorRecognizesOpenAndClosedTurns() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now: TimeInterval = 2_000_000_000
        let session = home.appendingPathComponent(
            ".codex/sessions/2026/01/01/rollout-2026-01-01T00-00-00-12345678-1234-1234-1234-123456789abc.jsonl"
        )
        let index = home.appendingPathComponent(".codex/session_index.jsonl")
        try write(
            """
            {"id":"12345678-1234-1234-1234-123456789abc","thread_name":"测试任务","updated_at":"2033-05-18T03:33:20Z"}
            """ + "\n", to: index)
        try write(
            """
            {"type":"event_msg","payload":{"type":"task_started"}}
            """ + "\n", to: session)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: now)], ofItemAtPath: session.path)
        let process = ProcessSupport { executable, arguments, _ in
            executable == "/bin/ps" && arguments.contains("args=") ? "/usr/local/bin/codex\n" : ""
        }
        let collector = CodexCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: now),
            settings: CollectorSettings(),
            files: FileSupport(),
            processes: process
        )
        XCTAssertEqual(
            collector.collect().cli.busy,
            [BusyItem(id: "12345678-1234-1234-1234-123456789abc", title: "测试任务")])
        try write(
            """
            {"type":"event_msg","payload":{"type":"task_started"}}
            {"type":"event_msg","payload":{"type":"task_complete"}}
            """ + "\n", to: session)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: now)], ofItemAtPath: session.path)
        XCTAssertTrue(collector.collect().cli.busy.isEmpty)
    }

    func testCodexCliCountIgnoresIdeManagedServerProcesses() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let psOutput = """
            /usr/local/bin/codex
            /fake-home/.vscode/extensions/openai.chatgpt-1.0-darwin-arm64/bin/macos-aarch64/codex -c features.code_mode_host=true app-server
            /fake-home/.cursor/extensions/openai.chatgpt-1.0-darwin-arm64/bin/macos-aarch64/codex -c features.code_mode_host=true app-server
            /Applications/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true app-server
            /usr/local/bin/codex mcp-server
            """
        let process = ProcessSupport { executable, arguments, _ in
            executable == "/bin/ps" && arguments.contains("args=") ? psOutput : ""
        }
        let collector = CodexCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 2_000_000_000),
            settings: CollectorSettings(),
            files: FileSupport(),
            processes: process
        )
        XCTAssertEqual(collector.collect().cli.detail, "1 个进程")
    }

    func testExpiredKimiCredentialsRemainUnchanged() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let credential = home.appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        let original =
            "{\"access_token\":\"example\",\"refresh_token\":\"do-not-touch\",\"expires_at\":1}"
        try write(original, to: credential)
        _ = QuotaCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 2_000_000_000),
            settings: CollectorSettings(onlineQuota: true),
            files: FileSupport()
        ).collect()
        XCTAssertEqual(try String(contentsOf: credential, encoding: .utf8), original)
    }

    func testPythonQuotaCacheKeysRemainCompatible() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent(".ai-statusbar/quota-cache.json")
        try write(
            """
            {"codex":{"plan":"test","windows":[{"kind":"5h","label":"5小时","used_percent":12.3,"resets_at":10}],"updated_at":1},"kimi":null,"zcode":null,"_online_quota_enabled":false,"_kimi_monthly_enabled":false,"_kimi_token_mtime":0}
            """, to: cache)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: cache.path)
        let quota = QuotaCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 101),
            settings: CollectorSettings(onlineQuota: false),
            files: FileSupport()
        ).collect()
        XCTAssertEqual(quota["codex"]??.plan, "test")
        XCTAssertEqual(quota["codex"]??.windows.first?.usedPercent, 12.3)
        // 旧 Python 缓存没有 window_minutes，解码为 nil 而不是失败。
        XCTAssertNil(quota["codex"]??.windows.first?.windowMinutes)
    }

    func testOnlineQuotaResponsesPreserveContractWithoutTouchingCredentials() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let auth = home.appendingPathComponent(".codex/auth.json")
        let kimi = home.appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        let providers = home.appendingPathComponent(".zcode/v2/model-providers.json")
        let kimiOriginal = "{\"access_token\":\"kimi-token\",\"expires_at\":3000000000}"
        try write(
            "{\"tokens\":{\"access_token\":\"codex-token\",\"account_id\":\"account\"}}", to: auth)
        try write(kimiOriginal, to: kimi)
        try write("[{\"name\":\"Z.AI - Coding Plan\",\"apiKey\":\"zcode-token\"}]", to: providers)
        var requested: [URLRequest] = []
        let collector = QuotaCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 2_000_000_000),
            settings: CollectorSettings(onlineQuota: true),
            files: FileSupport(),
            requestOverride: { request in
                requested.append(request)
                switch request.url?.host {
                case "chatgpt.com":
                    return [
                        "plan_type": "plus",
                        "rate_limit": [
                            "primary_window": [
                                "limit_window_seconds": 18_000, "used_percent": 10.25,
                                "reset_at": 20,
                            ]
                        ],
                    ]
                case "api.kimi.com":
                    return [
                        "usage": ["used": 25, "limit": 100, "resetTime": "2033-05-18T03:33:20Z"],
                        "user": ["membership": ["level": "pro"]],
                    ]
                case "api.z.ai":
                    return [
                        "code": 200,
                        "data": [
                            "level": "max",
                            "limits": [
                                [
                                    "type": "TOKENS_LIMIT", "number": 5, "percentage": 30.55,
                                    "nextResetTime": 42_000,
                                ]
                            ],
                        ],
                    ]
                default: return nil
                }
            }
        )
        let quota = collector.collect()
        XCTAssertEqual(quota["codex"]??.plan, "plus")
        XCTAssertEqual(quota["codex"]??.windows.first?.kind, "5h")
        XCTAssertEqual(quota["codex"]??.windows.first?.windowMinutes, 300)
        XCTAssertEqual(quota["kimi"]??.plan, "pro")
        XCTAssertEqual(quota["kimi"]??.windows.first?.usedPercent, 25)
        XCTAssertEqual(quota["kimi"]??.windows.first?.windowMinutes, 10_080)
        XCTAssertEqual(quota["zcode"]??.plan, "max")
        XCTAssertEqual(quota["zcode"]??.windows.first?.resetsAt, 42)
        XCTAssertEqual(quota["zcode"]??.windows.first?.windowMinutes, 300)
        XCTAssertEqual(try String(contentsOf: kimi, encoding: .utf8), kimiOriginal)
        XCTAssertEqual(
            Set(requested.compactMap { $0.url?.host }),
            Set(["chatgpt.com", "api.kimi.com", "api.z.ai"]))
        XCTAssertTrue(
            requested.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
            })
    }

    func testKimiCodeAndKimiWorkQuotasStaySeparate() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            "{\"access_token\":\"coding-token\",\"expires_at\":3000000000}",
            to: home.appendingPathComponent(".kimi-code/credentials/kimi-code.json"))
        try write(
            "{\"tokens\":{\"access_token\":\"desktop-token\"}}",
            to: home.appendingPathComponent(
                "Library/Application Support/kimi-desktop/bridge-store/token-store.json"))
        var requestedHosts: [String] = []
        let collector = QuotaCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 2_000_000_000),
            settings: CollectorSettings(onlineQuota: true),
            files: FileSupport(),
            requestOverride: { request in
                requestedHosts.append(request.url?.host ?? "")
                switch request.url?.host {
                case "api.kimi.com":
                    return [
                        "usage": [
                            "used": 25, "limit": 100,
                            "resetTime": "2033-05-18T03:33:20Z",
                        ],
                        "limits": [
                            [
                                "window": ["duration": 300],
                                "detail": [
                                    "used": 10, "limit": 100,
                                    "resetTime": "2033-05-18T03:33:20Z",
                                ],
                            ]
                        ],
                        "user": ["membership": ["level": "pro"]],
                    ]
                case "www.kimi.com":
                    return [
                        "subscriptionBalance": [
                            "amountUsedRatio": 0.2,
                            "kimiCodeUsedRatio": 0.08,
                            "expireTime": "2033-05-18T03:33:20Z",
                        ],
                        // 网页接口中的速率窗口不能替代 Coding API 的窗口。
                        "ratelimitCode5h": ["enabled": true, "ratio": 0.99],
                        "ratelimitCode7d": ["enabled": true, "ratio": 0.98],
                    ]
                default: return nil
                }
            }
        )
        let kimi = try XCTUnwrap(collector.collect()["kimi"] ?? nil)
        let kimiWork = try XCTUnwrap(collector.collect()["kimi-work"] ?? nil)
        XCTAssertEqual(kimi.plan, "pro")
        XCTAssertEqual(kimi.windows.map(\.kind), ["week", "5h"])
        XCTAssertEqual(kimi.windows.map(\.usedPercent), [25, 10])
        XCTAssertEqual(kimi.windows.map(\.windowMinutes), [10_080, 300])
        XCTAssertEqual(kimiWork.windows.map(\.kind), ["month"])
        XCTAssertEqual(kimiWork.windows.map(\.usedPercent), [20])
        // 月度窗口按对日续期：到期 2033-05-18，起点 2033-04-18，共 30 天。
        XCTAssertEqual(kimiWork.windows.first?.windowMinutes, 43_200)
        XCTAssertEqual(Set(requestedHosts), Set(["api.kimi.com", "www.kimi.com"]))
    }

    func testOnlyKimiWorkShowsMonthlyQuotaWithoutKimiCode() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            "{\"tokens\":{\"access_token\":\"desktop-token\"}}",
            to: home.appendingPathComponent(
                "Library/Application Support/kimi-desktop/bridge-store/token-store.json"))
        var requestedHosts: [String] = []
        let quota = QuotaCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 2_000_000_000),
            settings: CollectorSettings(onlineQuota: true),
            files: FileSupport(),
            requestOverride: { request in
                requestedHosts.append(request.url?.host ?? "")
                guard request.url?.host == "www.kimi.com" else { return nil }
                return [
                    "subscriptionBalance": [
                        "amountUsedRatio": 0.35,
                        "kimiCodeUsedRatio": 0.1,
                        "expireTime": "2033-05-18T03:33:20Z",
                    ],
                    // 即使网页响应包含这些字段，Kimi Work 也只展示月度额度。
                    "ratelimitCode5h": ["enabled": true, "ratio": 0.9],
                    "ratelimitCode7d": ["enabled": true, "ratio": 0.8],
                ]
            }
        ).collect()
        XCTAssertNil(quota["kimi"] ?? nil)
        let kimiWork = try XCTUnwrap(quota["kimi-work"] ?? nil)
        XCTAssertEqual(kimiWork.windows.map(\.kind), ["month"])
        XCTAssertEqual(kimiWork.windows.map(\.usedPercent), [35])
        XCTAssertEqual(requestedHosts, ["www.kimi.com"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".kimi-code").path))
    }

    func testMissingKimiWorkDoesNotRequestOrShowMonthlyQuota() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        var requestCount = 0
        let quota = QuotaCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 2_000_000_000),
            settings: CollectorSettings(onlineQuota: true),
            files: FileSupport(),
            requestOverride: { _ in
                requestCount += 1
                return nil
            }
        ).collect()
        XCTAssertNil(quota["kimi-work"] ?? nil)
        XCTAssertEqual(requestCount, 0)
    }

    func testOldMergedKimiCacheIsImmediatelySeparated() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent(".ai-statusbar/quota-cache.json")
        try write(
            """
            {"codex":null,"kimi":{"windows":[{"kind":"month","label":"本月","used_percent":50,"resets_at":10}],"updated_at":1},"zcode":null,"_online_quota_enabled":true,"_kimi_coding_token_mtime":0,"_kimi_token_mtime":0}
            """, to: cache)
        try touch(cache, at: 100)
        let quota = QuotaCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 101),
            settings: CollectorSettings(onlineQuota: true),
            files: FileSupport()
        ).collect()
        XCTAssertNil(quota["kimi"] ?? nil)
        XCTAssertNil(quota["kimi-work"] ?? nil)
    }

    func testExpiredKimiCodingTokenKeepsLastValidQuotaWithoutReloginNotice() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent(".ai-statusbar/quota-cache.json")
        try write(
            """
            {"codex":null,"kimi":{"plan":"pro","windows":[{"kind":"week","label":"7天","used_percent":28,"resets_at":10}],"updated_at":1},"zcode":null,"_online_quota_enabled":true,"_kimi_monthly_enabled":false,"_kimi_coding_token_mtime":90,"_kimi_token_mtime":0}
            """, to: cache)
        try touch(cache, at: 90)
        try write(
            "{\"access_token\":\"expired\",\"refresh_token\":\"present\",\"expires_at\":1}",
            to: home.appendingPathComponent(".kimi-code/credentials/kimi-code.json"))
        try touch(home.appendingPathComponent(".kimi-code/credentials/kimi-code.json"), at: 90)
        let quota = QuotaCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 100),
            settings: CollectorSettings(onlineQuota: true),
            files: FileSupport()
        ).collect()
        XCTAssertEqual(quota["kimi"]??.windows.first?.usedPercent, 28)
        XCTAssertNil(quota["kimi"]??.notice)
    }

    func testExpiredKimiCodingTokenDropsStaleReloginNotice() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent(".ai-statusbar/quota-cache.json")
        try write(
            """
            {"codex":null,"kimi":{"windows":[],"updated_at":1,"notice":"Kimi Code 登录已过期，请运行 kimi login"},"zcode":null,"_online_quota_enabled":true,"_kimi_monthly_enabled":false,"_kimi_coding_token_mtime":90,"_kimi_token_mtime":0}
            """, to: cache)
        try touch(cache, at: 90)
        let credential = home.appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        try write(
            "{\"access_token\":\"expired\",\"refresh_token\":\"present\",\"expires_at\":1}",
            to: credential)
        try touch(credential, at: 90)
        let quota = QuotaCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 500),
            settings: CollectorSettings(onlineQuota: true),
            files: FileSupport()
        ).collect()
        XCTAssertNil(quota["kimi"] ?? nil)
    }

    func testKimiLoginImmediatelyInvalidatesQuotaCache() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let credential = home.appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        try write("{\"access_token\":\"old\",\"expires_at\":1}", to: credential)
        try touch(credential, at: 90)
        var requestCount = 0
        func collector() -> QuotaCollector {
            QuotaCollector(
                environment: CollectorEnvironment(homeDirectory: home.path, now: 100),
                settings: CollectorSettings(onlineQuota: true),
                files: FileSupport(),
                requestOverride: { request in
                    guard request.url?.host == "api.kimi.com" else { return nil }
                    requestCount += 1
                    return [
                        "usage": [
                            "used": 28, "limit": 100,
                            "resetTime": "2033-05-18T03:33:20Z",
                        ]
                    ]
                })
        }
        XCTAssertNil(collector().collect()["kimi"] ?? nil)
        try write("{\"access_token\":\"new\",\"expires_at\":3000000000}", to: credential)
        try touch(credential, at: 95)
        let refreshed = collector().collect()["kimi"] ?? nil
        XCTAssertEqual(refreshed?.windows.first?.label, "7天")
        XCTAssertEqual(refreshed?.windows.first?.usedPercent, 28)
        XCTAssertEqual(requestCount, 1)
    }

    func testKimiAndClaudeBusyClosures() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now: TimeInterval = 2_000_000_000
        let state = home.appendingPathComponent(".kimi-code/sessions/work/session/state.json")
        let wire = home.appendingPathComponent(
            ".kimi-code/sessions/work/session/agents/main/wire.jsonl")
        let claude = home.appendingPathComponent(".claude/projects/project/session.jsonl")
        try write("{\"title\":\"Kimi 测试\"}", to: state)
        try write(
            """
            {"type":"context.append_loop_event","event":{"type":"step.begin","turnId":"10","uuid":"step"}}
            """ + "\n", to: wire)
        try write("{\"type\":\"user\",\"message\":{\"content\":\"开始\"}}\n", to: claude)
        try touch(wire, at: now)
        try touch(claude, at: now)
        let collectors = LocalCollectors(
            environment: CollectorEnvironment(homeDirectory: home.path, now: now),
            settings: CollectorSettings(), files: FileSupport(),
            processes: processSupport(["kimi", "claude"])
        )
        XCTAssertEqual(collectors.kimi().busy.first?.title, "Kimi 测试")
        XCTAssertEqual(collectors.claude().busy.count, 1)

        try write(
            """
            {"type":"context.append_loop_event","event":{"type":"step.begin","turnId":"10","uuid":"step"}}
            {"type":"context.append_loop_event","event":{"type":"step.end","turnId":"10","uuid":"step"}}
            """ + "\n", to: wire)
        try write(
            "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\"}]}}\n", to: claude
        )
        try touch(wire, at: now)
        try touch(claude, at: now)
        XCTAssertTrue(collectors.kimi().busy.isEmpty)
        XCTAssertTrue(collectors.claude().busy.isEmpty)
    }

    func testKimiWorkReadsConversationStatusAndTitle() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now: TimeInterval = 2_000_000_000
        let support = home.appendingPathComponent("Library/Application Support/kimi-desktop")
        let databasePath = support.appendingPathComponent(
            "daimon-share/daimon/agents/main/sessions/hosted-logical/conversations.sqlite")
        try FileManager.default.createDirectory(
            at: databasePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: databasePath.path)
        try database.execute(
            """
            CREATE TABLE conversations(
                conversation_key TEXT, title TEXT, updated_at_ms INTEGER)
            """)
        try database.execute(
            "INSERT INTO conversations VALUES(?,?,?)",
            binds: [.text("work-1"), .text("Kimi Work 测试"), .integer(Int64(now * 1_000))])
        try write(
            "{\"agent:main:main:conversation:work-1\":\"running\"}",
            to: support.appendingPathComponent("kimi-agent/conversation-statuses.json"))
        let collector = LocalCollectors(
            environment: CollectorEnvironment(homeDirectory: home.path, now: now),
            settings: CollectorSettings(), files: FileSupport(),
            processes: processSupport(["Kimi"])
        ).kimiWork()
        XCTAssertEqual(collector.busy, [BusyItem(id: "work-1", title: "Kimi Work 测试")])
        XCTAssertEqual(collector.latest?.title, "Kimi Work 测试")
    }

    func testKimiWorkUsageExcludesInternalHelperSessions() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let timestamp = try XCTUnwrap(DateSupport.timestamp("2033-05-18T03:33:20Z"))
        let root = home.appendingPathComponent(
            "Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions/workspace"
        )
        let conversation = root.appendingPathComponent("conv-main/agents/main/wire.jsonl")
        let helper = root.appendingPathComponent("ctitle-helper/agents/main/wire.jsonl")
        let usage =
            "{\"type\":\"usage.record\",\"time\":2000000000000,\"usage\":{\"inputOther\":3,\"output\":4,\"inputCacheRead\":5}}\n"
        try write(usage, to: conversation)
        try write(usage, to: helper)
        try touch(conversation, at: timestamp)
        try touch(helper, at: timestamp)
        let data = try XCTUnwrap(
            UsageCollector(
                environment: CollectorEnvironment(homeDirectory: home.path, now: timestamp),
                files: FileSupport()
            ).collect())
        XCTAssertEqual(data.tools["kimi-work"], UsageEntry(input: 3, output: 4, cache: 5))
    }

    func testHermesAndZCodeDatabaseCollectors() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now: TimeInterval = 2_000_000_000
        let hermesPath = home.appendingPathComponent(".hermes/state.db")
        try FileManager.default.createDirectory(
            at: hermesPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hermes = try SQLiteDatabase(path: hermesPath.path)
        try hermes.execute(
            "CREATE TABLE sessions(id TEXT, title TEXT, started_at REAL, archived INT)")
        try hermes.execute("CREATE TABLE session_model_usage(session_id TEXT, last_seen REAL)")
        try hermes.execute(
            "INSERT INTO sessions VALUES('h1','Hermes 测试',?,0)", binds: [.real(now - 1)])
        try hermes.execute(
            "INSERT INTO session_model_usage VALUES('h1',?)", binds: [.real(now - 1)])

        let zcodePath = home.appendingPathComponent(".zcode/v2/tasks-index.sqlite")
        try FileManager.default.createDirectory(
            at: zcodePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let zcode = try SQLiteDatabase(path: zcodePath.path)
        try zcode.execute(
            "CREATE TABLE tasks(task_id TEXT, title TEXT, updated_at REAL, deleted INT)")
        try zcode.execute(
            "INSERT INTO tasks VALUES('sess_test','ZCode 测试',?,0)", binds: [.real(now * 1_000)])
        let rollout = home.appendingPathComponent(".zcode/cli/rollout/model-io-sess_test.jsonl")
        try write("{}\n", to: rollout)
        try touch(rollout, at: now)

        let collectors = LocalCollectors(
            environment: CollectorEnvironment(homeDirectory: home.path, now: now),
            settings: CollectorSettings(), files: FileSupport(),
            processes: processSupport(["Hermes", "ZCode"])
        )
        XCTAssertEqual(collectors.hermes().busy, [BusyItem(id: "h1", title: "Hermes 测试")])
        XCTAssertEqual(collectors.zcode().busy, [BusyItem(id: "sess_test", title: "ZCode 测试")])
    }

    func testUsageIncrementalScanDoesNotDoubleCount() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let timestamp = try XCTUnwrap(DateSupport.timestamp("2033-05-18T03:33:20Z"))
        let log = home.appendingPathComponent(
            ".codex/sessions/2033/05/18/rollout-2033-05-18T03-33-20-12345678-1234-1234-1234-123456789abc.jsonl"
        )
        try write(
            """
            {"timestamp":"2033-05-18T03:33:20Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":30,"cached_input_tokens":12,"output_tokens":7}}}}
            """ + "\n", to: log)
        try touch(log, at: timestamp)
        let collector = UsageCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: timestamp),
            files: FileSupport()
        )
        let first = try XCTUnwrap(collector.collect())
        let second = try XCTUnwrap(collector.collect())
        XCTAssertEqual(first.tools["codex"], UsageEntry(input: 18, output: 7, cache: 12))
        XCTAssertEqual(second.tools["codex"], first.tools["codex"])
        XCTAssertEqual(second.total, first.total)
    }
}
