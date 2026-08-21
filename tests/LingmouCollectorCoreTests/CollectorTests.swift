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
        let codexState = UsageParseState()
        // turn_context 行本身不产出用量，只更新状态里的"当前模型"
        XCTAssertNil(
            UsageParsers.codex(
                """
                {"timestamp":"2026-08-13T01:02:03Z","type":"turn_context","payload":{"turn_id":"t1","model":"gpt-5.6-sol"}}
                """, codexState))
        let codexCounted = try XCTUnwrap(
            UsageParsers.codex(
                """
                {"timestamp":"2026-08-13T01:02:03Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":30,"cached_input_tokens":12,"output_tokens":7}}}}
                """, codexState))
        XCTAssertEqual(codexCounted.input, 18)
        XCTAssertEqual(codexCounted.output, 7)
        XCTAssertEqual(codexCounted.cache, 12)
        XCTAssertEqual(codexCounted.model, "gpt-5.6-sol")

        let kimi = try XCTUnwrap(
            UsageParsers.kimi(
                """
                {"type":"usage.record","time":10000,"model":"kimi-code/k3","usage":{"inputOther":3,"output":4,"inputCacheRead":5}}
                """, UsageParseState()))
        XCTAssertEqual(kimi, ParsedUsage(timestamp: 10, input: 3, output: 4, cache: 5, model: "kimi-code/k3"))

        let claude = try XCTUnwrap(
            UsageParsers.claude(
                """
                {"timestamp":"2026-08-13T01:02:03Z","message":{"model":"glm-5.2","usage":{"input_tokens":8,"output_tokens":9,"cache_read_input_tokens":10}}}
                """, UsageParseState()))
        XCTAssertEqual(claude.input, 8)
        XCTAssertEqual(claude.output, 9)
        XCTAssertEqual(claude.cache, 10)
        XCTAssertEqual(claude.model, "glm-5.2")

        let zcode = try XCTUnwrap(
            UsageParsers.zcode(
                """
                {"completedAt":"2026-08-13T01:02:03Z","model":{"modelId":"GLM-5.3","providerId":"builtin"},"response":{"usage":{"inputTokens":20,"outputTokens":6,"cacheReadTokens":11}}}
                """, UsageParseState()))
        XCTAssertEqual(zcode.input, 9)
        XCTAssertEqual(zcode.output, 6)
        XCTAssertEqual(zcode.cache, 11)
        XCTAssertEqual(zcode.model, "GLM-5.3")

        // Codex 会话中途切换模型：turn_context 更新状态后，后续计数归属新模型
        let switchState = UsageParseState()
        _ = UsageParsers.codex(
            """
            {"timestamp":"2026-08-13T01:02:04Z","type":"turn_context","payload":{"model":"gpt-5.1"}}
            """, switchState)
        let switched = try XCTUnwrap(
            UsageParsers.codex(
                """
                {"timestamp":"2026-08-13T01:02:05Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":1,"cached_input_tokens":0}}}}
                """, switchState))
        XCTAssertEqual(switched.model, "gpt-5.1")
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

    /// 新版 ZCode 把提供商存进 config.json 的 provider 字典（密钥在 options 里、
    /// 按 builtin id 标识），且名称大小写与旧版数组写法不同；此时应从 config.json
    /// 取启用项的密钥，而不是依赖已不存在的 model-providers.json。
    func testZCodeQuotaReadsNewConfigProviderLayout() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            """
            {"provider":{
              "builtin:bigmodel-coding-plan":{"name":"BigModel - Coding Plan","enabled":true,
                "options":{"apiKey":"new-layout-key","baseURL":"https://open.bigmodel.cn/api/anthropic"}},
              "builtin:zai-coding-plan":{"name":"Z.ai - Coding Plan","enabled":false,
                "options":{"apiKey":"","baseURL":"https://api.z.ai/api/anthropic"}}
            }}
            """,
            to: home.appendingPathComponent(".zcode/v2/config.json"))
        var authHeaders: [String] = []
        let collector = QuotaCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 2_000_000_000),
            settings: CollectorSettings(onlineQuota: true),
            files: FileSupport(),
            requestOverride: { request in
                guard request.url?.host == "open.bigmodel.cn" else { return nil }
                authHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
                return [
                    "code": 200,
                    "data": [
                        "level": "lite",
                        "limits": [
                            [
                                "type": "TOKENS_LIMIT", "number": 5, "percentage": 25.5,
                                "nextResetTime": 42_000,
                            ]
                        ],
                    ],
                ]
            }
        )
        let quota = collector.collect()
        XCTAssertEqual(quota["zcode"]??.plan, "lite")
        XCTAssertEqual(quota["zcode"]??.windows.first?.kind, "5h")
        XCTAssertEqual(quota["zcode"]??.windows.first?.usedPercent, 25.5)
        XCTAssertEqual(quota["zcode"]??.windows.first?.resetsAt, 42)
        XCTAssertEqual(quota["zcode"]??.windows.first?.windowMinutes, 300)
        XCTAssertEqual(authHeaders, ["Bearer new-layout-key"])
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

    func testKimiBadgeUsesSubscriptionTitleWhenWorkPresent() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            "{\"access_token\":\"coding-token\",\"expires_at\":3000000000}",
            to: home.appendingPathComponent(".kimi-code/credentials/kimi-code.json"))
        try write(
            "{\"tokens\":{\"access_token\":\"desktop-token\"}}",
            to: home.appendingPathComponent(
                "Library/Application Support/kimi-desktop/bridge-store/token-store.json"))
        let quota = QuotaCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 2_000_000_000),
            settings: CollectorSettings(onlineQuota: true),
            files: FileSupport(),
            requestOverride: { request in
                switch request.url?.host {
                case "api.kimi.com":
                    return [
                        "usage": ["used": 25, "limit": 100, "resetTime": "2033-05-18T03:33:20Z"],
                        "user": ["membership": ["level": "LEVEL_ADVANCED"]],
                    ]
                case "www.kimi.com":
                    // GetSubscriptionStats 与 GetSubscription 路径有前缀包含关系，先匹配长的
                    if request.url?.path.contains("GetSubscriptionStats") == true {
                        return [
                            "subscriptionBalance": [
                                "amountUsedRatio": 0.2,
                                "kimiCodeUsedRatio": 0.08,
                                "expireTime": "2033-05-18T03:33:20Z",
                            ]
                        ]
                    }
                    return ["subscription": ["goods": ["title": "Allegro"]]]
                default: return nil
                }
            }
        ).collect()
        // Kimi Work 配额携带档位名，并提升为 Kimi Code 的徽标
        XCTAssertEqual(quota["kimi-work"]??.plan, "Allegro")
        XCTAssertEqual(quota["kimi"]??.plan, "Allegro")
    }

    func testKimiBadgeFallsBackToCodingLevelWithoutWork() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(
            "{\"access_token\":\"coding-token\",\"expires_at\":3000000000}",
            to: home.appendingPathComponent(".kimi-code/credentials/kimi-code.json"))
        let quota = QuotaCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: 2_000_000_000),
            settings: CollectorSettings(onlineQuota: true),
            files: FileSupport(),
            requestOverride: { request in
                guard request.url?.host == "api.kimi.com" else { return nil }
                return [
                    "usage": ["used": 25, "limit": 100, "resetTime": "2033-05-18T03:33:20Z"],
                    "user": ["membership": ["level": "LEVEL_ADVANCED"]],
                ]
            }
        ).collect()
        // 未装 Kimi Work 的机器拿不到订阅档位名，回退 Coding API 的原始等级
        XCTAssertEqual(quota["kimi"]??.plan, "LEVEL_ADVANCED")
        XCTAssertNil(quota["kimi-work"] ?? nil)
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
        // 只访问 www.kimi.com（额度 + 订阅档位名各一次），绝不碰 Coding API
        XCTAssertEqual(Set(requestedHosts), ["www.kimi.com"])
        XCTAssertEqual(requestedHosts.count, 2)
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

    func testHermesTurnLeaseAndActivityHeartbeat() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now: TimeInterval = 2_000_000_000
        let hermesPath = home.appendingPathComponent(".hermes/state.db")
        try FileManager.default.createDirectory(
            at: hermesPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hermes = try SQLiteDatabase(path: hermesPath.path)
        try hermes.execute(
            """
            CREATE TABLE sessions(
                id TEXT, title TEXT, started_at REAL, archived INT, last_activity_at REAL)
            """)
        try hermes.execute("CREATE TABLE session_model_usage(session_id TEXT, last_seen REAL)")
        try hermes.execute(
            """
            CREATE TABLE session_turn_leases(
                conversation_id TEXT, holder TEXT, acquired_at REAL, expires_at REAL)
            """)
        // last_seen 已超出 5 分钟窗口，但租约存活 → 秒级判定工作中。
        try hermes.execute(
            "INSERT INTO sessions VALUES('h1','租约会话',?,0,?)",
            binds: [.real(now - 3_600), .real(now - 3_600)])
        try hermes.execute(
            "INSERT INTO session_model_usage VALUES('h1',?)", binds: [.real(now - 3_600)])
        try hermes.execute(
            "INSERT INTO session_turn_leases VALUES('h1','pid=1',?,?)",
            binds: [.real(now - 60), .real(now + 240)])
        // 新会话首轮无租约，靠 last_activity_at 心跳判定。
        try hermes.execute(
            "INSERT INTO sessions VALUES('h2','新会话',?,0,?)",
            binds: [.real(now - 30), .real(now - 30)])

        let collectors = LocalCollectors(
            environment: CollectorEnvironment(homeDirectory: home.path, now: now),
            settings: CollectorSettings(), files: FileSupport(),
            processes: processSupport(["Hermes"])
        )
        let busy = collectors.hermes().busy
        XCTAssertEqual(
            busy,
            [
                BusyItem(id: "h1", title: "租约会话"),
                BusyItem(id: "h2", title: "新会话"),
            ])
        XCTAssertEqual(collectors.hermes().activity, now - 30)

        // 租约过期、心跳超出 90 秒 → 不再工作中。
        try hermes.execute("DELETE FROM session_turn_leases")
        try hermes.execute(
            "INSERT INTO session_turn_leases VALUES('h1','pid=1',?,?)",
            binds: [.real(now - 400), .real(now - 100)])
        try hermes.execute(
            "UPDATE sessions SET last_activity_at = ? WHERE id = 'h2'", binds: [.real(now - 200)])
        XCTAssertTrue(collectors.hermes().busy.isEmpty)
    }

    func testHermesRotatedLeaseFallsBackToSegmentUsageTitle() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now: TimeInterval = 2_000_000_000
        let hermesPath = home.appendingPathComponent(".hermes/state.db")
        try FileManager.default.createDirectory(
            at: hermesPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hermes = try SQLiteDatabase(path: hermesPath.path)
        try hermes.execute(
            """
            CREATE TABLE sessions(
                id TEXT, title TEXT, started_at REAL, archived INT, last_activity_at REAL)
            """)
        try hermes.execute("CREATE TABLE session_model_usage(session_id TEXT, last_seen REAL)")
        try hermes.execute(
            """
            CREATE TABLE session_turn_leases(
                conversation_id TEXT, holder TEXT, acquired_at REAL, expires_at REAL)
            """)
        // 血缘根已被压缩归档、查无标题；当前 segment 的用量行仍在。
        try hermes.execute(
            "INSERT INTO sessions VALUES('seg2','轮转后会话',?,0,?)",
            binds: [.real(now - 10), .real(now - 600)])
        try hermes.execute(
            "INSERT INTO session_model_usage VALUES('seg2',?)", binds: [.real(now - 10)])
        try hermes.execute(
            "INSERT INTO session_turn_leases VALUES('root1','pid=1',?,?)",
            binds: [.real(now - 60), .real(now + 240)])

        let collectors = LocalCollectors(
            environment: CollectorEnvironment(homeDirectory: home.path, now: now),
            settings: CollectorSettings(), files: FileSupport(),
            processes: processSupport(["Hermes"])
        )
        XCTAssertEqual(
            collectors.hermes().busy, [BusyItem(id: "seg2", title: "轮转后会话")])
    }

    func testZcodeActivityVersusTurnCompletion() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now: TimeInterval = 2_000_000_000
        let index = home.appendingPathComponent(".zcode/v2/tasks-index.sqlite")
        try FileManager.default.createDirectory(
            at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tasks = try SQLiteDatabase(path: index.path)
        try tasks.execute(
            """
            CREATE TABLE tasks(task_id TEXT, title TEXT, updated_at REAL, deleted INT)
            """)
        try tasks.execute(
            "INSERT INTO tasks VALUES('sess_onset','ZCode 新会话',?,0)",
            binds: [.real(now * 1_000)])
        try tasks.execute(
            "INSERT INTO tasks VALUES('sess_done','ZCode 已完成',?,0)",
            binds: [.real(now * 1_000)])

        let usage = home.appendingPathComponent(".zcode/cli/db/db.sqlite")
        try FileManager.default.createDirectory(
            at: usage.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: usage.path)
        try database.execute(
            "CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, time_created REAL, time_updated REAL, data TEXT)")
        try database.execute(
            "CREATE TABLE turn_usage(session_id TEXT, turn_id TEXT, status TEXT, started_at REAL, completed_at REAL)")
        // 新会话首轮：用户消息提交即落库、尚无回合完成 → 秒级判定工作中。
        try database.execute(
            "INSERT INTO part VALUES('p1','m1','sess_onset',?,?,'{}')",
            binds: [.real((now - 5) * 1_000), .real((now - 5) * 1_000)])
        // 已结束回合：活动 3 秒前、完成戳 1 秒前（晚于活动）→ 立即转空闲。
        try database.execute(
            "INSERT INTO part VALUES('p2','m2','sess_done',?,?,'{}')",
            binds: [.real((now - 3) * 1_000), .real((now - 3) * 1_000)])
        try database.execute(
            "INSERT INTO turn_usage VALUES('sess_done','t1','completed',?,?)",
            binds: [.real((now - 60) * 1_000), .real((now - 1) * 1_000)])
        // 僵尸活动：超出 busy 窗口且无完成戳 → 不误报。
        try database.execute(
            "INSERT INTO part VALUES('p3','m3','sess_stale',?,?,'{}')",
            binds: [.real((now - 600) * 1_000), .real((now - 600) * 1_000)])

        let collectors = LocalCollectors(
            environment: CollectorEnvironment(homeDirectory: home.path, now: now),
            settings: CollectorSettings(), files: FileSupport(),
            processes: processSupport(["ZCode"])
        )
        XCTAssertEqual(
            collectors.zcode().busy, [BusyItem(id: "sess_onset", title: "ZCode 新会话")])
    }

    func testZcodeNewTurnAfterCompletionStaysBusy() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now: TimeInterval = 2_000_000_000
        let usage = home.appendingPathComponent(".zcode/cli/db/db.sqlite")
        try FileManager.default.createDirectory(
            at: usage.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: usage.path)
        try database.execute(
            "CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, time_created REAL, time_updated REAL, data TEXT)")
        try database.execute(
            "CREATE TABLE turn_usage(session_id TEXT, turn_id TEXT, status TEXT, started_at REAL, completed_at REAL)")
        // 上一回合 60 秒前完成，新用户消息 2 秒前提交（晚于完成戳）→ 工作中。
        try database.execute(
            "INSERT INTO turn_usage VALUES('sess_live','t1','completed',?,?)",
            binds: [.real((now - 120) * 1_000), .real((now - 60) * 1_000)])
        try database.execute(
            "INSERT INTO part VALUES('p1','m1','sess_live',?,?,'{}')",
            binds: [.real((now - 2) * 1_000), .real((now - 2) * 1_000)])

        let state = LocalCollectors(
            environment: CollectorEnvironment(homeDirectory: home.path, now: now),
            settings: CollectorSettings(), files: FileSupport(),
            processes: processSupport(["ZCode"])
        ).zcode()
        XCTAssertEqual(state.busy, [BusyItem(id: "sess_live", title: "(未知任务)")])
        XCTAssertEqual(state.activity, now - 2, accuracy: 0.001)
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
            {"timestamp":"2033-05-18T03:33:19Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
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
        XCTAssertEqual(
            second.models?["gpt-5.6-sol"], UsageEntry(input: 18, output: 7, cache: 12))
    }

    /// 断点恰好落在 turn_context 之后：恢复扫描时没有新的 turn_context，
    /// Codex 计数必须归属到 offsets 里持久化的"当前模型"，而不是丢失归属
    func testCodexIncrementalResumeKeepsModelAttribution() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let timestamp = try XCTUnwrap(DateSupport.timestamp("2033-05-18T03:33:20Z"))
        let log = home.appendingPathComponent(
            ".codex/sessions/2033/05/18/rollout-2033-05-18T03-33-20-12345678-1234-1234-1234-123456789abc.jsonl"
        )
        try write(
            """
            {"timestamp":"2033-05-18T03:33:19Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
            {"timestamp":"2033-05-18T03:33:20Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":30,"cached_input_tokens":12,"output_tokens":7}}}}
            """ + "\n", to: log)
        try touch(log, at: timestamp)
        var collector = UsageCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: timestamp),
            files: FileSupport()
        )
        _ = try collector.collect()

        let later = try XCTUnwrap(DateSupport.timestamp("2033-05-18T03:34:20Z"))
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(
            contentsOf: Data(
                """
                {"timestamp":"2033-05-18T03:34:20Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40,"cached_input_tokens":2,"output_tokens":9}}}}
                """.utf8 + [0x0A]))
        try handle.closeFile()
        try touch(log, at: later)
        collector = UsageCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: later),
            files: FileSupport()
        )
        let resumed = try XCTUnwrap(collector.collect())
        XCTAssertEqual(
            resumed.tools["codex"], UsageEntry(input: 18 + 38, output: 7 + 9, cache: 12 + 2))
        XCTAssertEqual(
            resumed.models?["gpt-5.6-sol"],
            UsageEntry(input: 18 + 38, output: 7 + 9, cache: 12 + 2))
        XCTAssertNil(resumed.models?["未知模型"])
    }

    /// 旧版 daily 表没有 model 列：迁移应丢弃旧聚合并重扫日志，重建出带模型的计数
    func testLegacyDailySchemaRebuildsWithModelDimension() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let timestamp = try XCTUnwrap(DateSupport.timestamp("2033-05-18T03:33:20Z"))
        let log = home.appendingPathComponent(
            ".codex/sessions/2033/05/18/rollout-2033-05-18T03-33-20-12345678-1234-1234-1234-123456789abc.jsonl"
        )
        try write(
            """
            {"timestamp":"2033-05-18T03:33:19Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
            {"timestamp":"2033-05-18T03:33:20Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":30,"cached_input_tokens":12,"output_tokens":7}}}}
            """ + "\n", to: log)
        try touch(log, at: timestamp)

        let databasePath = home.appendingPathComponent(".ai-statusbar/usage.sqlite")
        try FileManager.default.createDirectory(
            at: databasePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = try SQLiteDatabase(path: databasePath.path)
        try legacy.execute(
            """
            CREATE TABLE daily(date TEXT, tool TEXT, input INT, output INT, cache INT,
                PRIMARY KEY(date, tool))
            """)
        try legacy.execute(
            "INSERT INTO daily VALUES('2033-05-18','codex',999,999,999)")
        try legacy.execute(
            "CREATE TABLE offsets(path TEXT PRIMARY KEY, offset INT, mtime REAL, last_key TEXT)")
        try legacy.execute(
            "INSERT INTO offsets VALUES(?, 0, 0, NULL)", binds: [.text(log.path)])

        let collector = UsageCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: timestamp),
            files: FileSupport()
        )
        let data = try XCTUnwrap(collector.collect())
        // 旧聚合（999）被丢弃，重扫后只有日志里的真实计数，且带模型维度
        XCTAssertEqual(data.tools["codex"], UsageEntry(input: 18, output: 7, cache: 12))
        XCTAssertEqual(data.models?["gpt-5.6-sol"], UsageEntry(input: 18, output: 7, cache: 12))
    }

    /// ZCode 用量走 db.sqlite 的 model_usage：历史行按 started_at 回填各自日期，
    /// cancelled/error 行不计；重复采集不双计
    func testZcodeUsageReadsModelUsageDatabaseWithHistoryBackfill() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = try XCTUnwrap(DateSupport.timestamp("2033-05-18T03:33:20Z"))
        let dbDirectory = home.appendingPathComponent(".zcode/cli/db")
        try FileManager.default.createDirectory(
            at: dbDirectory, withIntermediateDirectories: true)
        let zcode = try SQLiteDatabase(
            path: dbDirectory.appendingPathComponent("db.sqlite").path)
        try zcode.execute(
            """
            CREATE TABLE model_usage(
                id TEXT PRIMARY KEY, model_id TEXT, status TEXT, started_at INTEGER,
                input_tokens INTEGER, output_tokens INTEGER, cache_read_input_tokens INTEGER)
            """)
        // 今天一条 + 三天前一条；cancelled/error 数值无效应被忽略
        try zcode.execute(
            "INSERT INTO model_usage VALUES('r1','GLM-5.3','completed',?,?,?,?)",
            binds: [
                .integer(Int64((now - 60) * 1000)), .integer(200), .integer(30),
                .integer(50),
            ])
        try zcode.execute(
            "INSERT INTO model_usage VALUES('r2','GLM-5.2','completed',?,?,?,?)",
            binds: [
                .integer(Int64((now - 3 * 86_400) * 1000)), .integer(1000), .integer(70),
                .integer(300),
            ])
        try zcode.execute(
            "INSERT INTO model_usage VALUES('r3','GLM-5.3','cancelled',?,?,?,?)",
            binds: [.integer(Int64((now - 60) * 1000)), .integer(999), .integer(999), .integer(999)])
        try zcode.execute(
            "INSERT INTO model_usage VALUES('r4','GLM-5.3','error',?,?,?,?)",
            binds: [.integer(Int64((now - 60) * 1000)), .integer(888), .integer(888), .integer(888)])

        var collector = UsageCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: now),
            files: FileSupport()
        )
        let first = try XCTUnwrap(collector.collect())
        // 今日视图只含今天的请求（input 已扣掉 cache 读）
        XCTAssertEqual(first.tools["zcode"], UsageEntry(input: 150, output: 30, cache: 50))
        XCTAssertEqual(first.models?["glm-5.3"], UsageEntry(input: 150, output: 30, cache: 50))
        // 近七日聚合包含历史行，且落到各自日期（r2 不进今日）
        let weeklyTotal = UsageEntry(input: 150 + 700, output: 30 + 70, cache: 50 + 300)
        XCTAssertEqual(first.weekly?.tools["zcode"], weeklyTotal)
        XCTAssertEqual(first.weekly?.models?["glm-5.2"], UsageEntry(input: 700, output: 70, cache: 300))

        // 第二次采集：快照已建，差分为零，不双计
        collector = UsageCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: now),
            files: FileSupport()
        )
        let second = try XCTUnwrap(collector.collect())
        XCTAssertEqual(second.tools["zcode"], first.tools["zcode"])
        XCTAssertEqual(second.weekly?.tools["zcode"], weeklyTotal)
    }

    /// 首次切换到 db 数据源时，此前 rollout 文件扫描记入的 zcode 行应被清掉重记，防双计
    func testZcodeDatabaseReplacesFileScanRowsOnFirstRun() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = try XCTUnwrap(DateSupport.timestamp("2033-05-18T03:33:20Z"))
        // 预置：daily 里已有文件扫描记入的假数据（999），且尚无 zcode_snap
        let databasePath = home.appendingPathComponent(".ai-statusbar/usage.sqlite")
        try FileManager.default.createDirectory(
            at: databasePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let preexisting = try SQLiteDatabase(path: databasePath.path)
        try preexisting.execute(
            """
            CREATE TABLE daily(date TEXT, tool TEXT, model TEXT NOT NULL DEFAULT '',
                input INT, output INT, cache INT, PRIMARY KEY(date, tool, model))
            """)
        try preexisting.execute(
            "INSERT INTO daily VALUES(?, 'zcode', '', 999, 999, 999)",
            binds: [.text(DateSupport.localDay(now))])

        let dbDirectory = home.appendingPathComponent(".zcode/cli/db")
        try FileManager.default.createDirectory(
            at: dbDirectory, withIntermediateDirectories: true)
        let zcode = try SQLiteDatabase(
            path: dbDirectory.appendingPathComponent("db.sqlite").path)
        try zcode.execute(
            """
            CREATE TABLE model_usage(
                id TEXT PRIMARY KEY, model_id TEXT, status TEXT, started_at INTEGER,
                input_tokens INTEGER, output_tokens INTEGER, cache_read_input_tokens INTEGER)
            """)
        try zcode.execute(
            "INSERT INTO model_usage VALUES('r1','GLM-5.3','completed',?,?,?,?)",
            binds: [.integer(Int64(now * 1000)), .integer(100), .integer(10), .integer(0)])

        let collector = UsageCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: now),
            files: FileSupport()
        )
        let data = try XCTUnwrap(collector.collect())
        XCTAssertEqual(data.tools["zcode"], UsageEntry(input: 100, output: 10, cache: 0))
    }

    /// db.sqlite 不存在（旧版 ZCode / 未安装）时回退 rollout 文件扫描
    func testZcodeFallsBackToRolloutFilesWhenDatabaseMissing() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = try XCTUnwrap(DateSupport.timestamp("2033-05-18T03:33:20Z"))
        let log = home.appendingPathComponent(
            ".zcode/cli/rollout/model-io-sess_test-1234.jsonl")
        try write(
            """
            {"completedAt":"2033-05-18T03:33:19Z","model":{"modelId":"GLM-5.3"},"response":{"usage":{"inputTokens":20,"outputTokens":6,"cacheReadTokens":11}}}
            """ + "\n", to: log)
        try touch(log, at: now)
        let collector = UsageCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: now),
            files: FileSupport()
        )
        let data = try XCTUnwrap(collector.collect())
        XCTAssertEqual(data.tools["zcode"], UsageEntry(input: 9, output: 6, cache: 11))
        XCTAssertEqual(data.models?["glm-5.3"], UsageEntry(input: 9, output: 6, cache: 11))
    }
}
