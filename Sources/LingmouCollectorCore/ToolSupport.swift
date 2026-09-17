import Foundation

/// Built-in support declarations are kept beside the collector, so frontends do not guess capabilities.
public enum ToolSupport {
    public static func capabilities(for key: String) -> ToolCapabilities {
        switch key {
        case "codex-ide", "codex-cli":
            return ToolCapabilities(eventPhases: ["ended", "interrupted", "waiting_input"],
                                    quota: true, navigation: key == "codex-cli" ? "host" : "application")
        case "claude":
            return ToolCapabilities(eventPhases: ["ended"], navigation: "host")
        case "zcode":
            return ToolCapabilities(eventPhases: ["ended", "interrupted"], quota: true)
        case "kimi":
            return ToolCapabilities(eventPhases: ["ended"], quota: true, navigation: "host")
        case "hermes":
            return ToolCapabilities(eventPhases: ["ended", "interrupted"], navigation: "host")
        case "kimi-work":
            return ToolCapabilities(eventPhases: ["ended"], quota: true)
        case "dsh":
            return ToolCapabilities(eventPhases: ["ended"], navigation: "web")
        default:
            return ToolCapabilities(usage: false, navigation: "unsupported")
        }
    }

    static func sourcePath(for key: String, environment: CollectorEnvironment) -> String {
        switch key {
        case "codex-ide", "codex-cli": return environment.path(".codex", "sessions")
        case "kimi": return environment.path(".kimi-code", "sessions")
        case "kimi-work": return environment.path("Library", "Application Support", "kimi-desktop")
        case "claude": return environment.path(".claude", "projects")
        case "hermes": return environment.path(".hermes", "state.db")
        case "zcode": return environment.path(".zcode")
        case "dsh": return environment.path(".dsh")
        default: return ""
        }
    }

    /// 配额快照保鲜期按窗口长度分级：月窗一天、周窗十二小时、小时级窗口一小时。
    /// 部分工具的 token 只在真正发会话时才刷新，固定十分钟阈值会把仍有参考价值
    /// 的历史快照误标为过期。窗口本身过期（resetsAt 已过）由展示层另行过滤。
    public static func quotaFreshHorizon(windows: [QuotaWindow]) -> TimeInterval {
        var horizon: TimeInterval = 3_600
        for window in windows {
            switch window.kind {
            case "month": horizon = max(horizon, 86_400)
            case "week": horizon = max(horizon, 43_200)
            default: break
            }
        }
        return horizon
    }

    static func health(for key: String, raw: RawToolState, quota: ToolQuota?,
                       environment: CollectorEnvironment, settings: CollectorSettings) -> ToolHealth {
        let caps = capabilities(for: key)
        let path = sourcePath(for: key, environment: environment)
        let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path)
        let state: String
        let message: String
        if let error = raw.sourceError {
            state = "error"; message = error
        } else if exists && !FileManager.default.isReadableFile(atPath: path) {
            state = "error"; message = "无法读取本地数据，请检查文件访问权限"
        } else if !exists && !raw.processOn {
            state = "not_detected"; message = "尚未发现本地会话数据或运行中的工具"
        } else if !raw.processOn && raw.busy.isEmpty {
            state = "not_running"; message = "已发现本地数据，工具当前未运行"
        } else if raw.activity == 0 && raw.busy.isEmpty {
            state = "no_data"; message = "工具已运行，等待首次会话数据"
        } else {
            state = "ready"; message = "本地状态读取正常"
        }
        let quotaState: String
        if !caps.quota {
            quotaState = "unsupported"
        } else if let quota, !quota.windows.isEmpty {
            quotaState = environment.now - Double(quota.updatedAt)
                    > Self.quotaFreshHorizon(windows: quota.windows)
                || quota.notice != nil ? "stale" : (settings.onlineQuota ? "ready" : "local")
        } else if !settings.onlineQuota {
            quotaState = "disabled"
        } else if let notice = quota?.notice, notice.contains("登录") || notice.contains("凭证不存在") {
            quotaState = "login_required"
        } else {
            quotaState = "unavailable"
        }
        return ToolHealth(state: state, message: message, checkedAt: environment.now,
                          sourceUpdatedAt: raw.activity > 0 ? raw.activity : nil, quotaState: quotaState)
    }
}
