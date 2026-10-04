import Foundation

/// Codex cloud tasks run on OpenAI's servers, so nothing on the Mac sees them happen. But the
/// Codex CLI can list them (`codex cloud list --json`) using the login you already have, so
/// Turbo polls that and turns status changes into events. No setup beyond being signed in to
/// the Codex CLI.
public enum CodexCloud {
    public struct Task: Equatable, Sendable {
        public var id: String
        public var url: URL?
        public var title: String
        public var status: String
        public var updatedAt: String
        public var environment: String?
        public var summary: String?

        public var phase: Phase { Phase(status: status) }
    }

    /// The CLI's status strings aren't documented, so match them loosely.
    public enum Phase: Equatable, Sendable {
        case working
        case done
        case failed
        case unknown

        public init(status: String) {
            let s = status.lowercased()
            func has(_ words: [String]) -> Bool { words.contains { s.contains($0) } }
            if has(["error", "fail", "cancel", "abort", "timeout", "timed_out"]) {
                self = .failed
            } else if has(["pending", "queue", "running", "progress", "working", "started", "submitted", "creating", "thinking"]) {
                self = .working
            } else if has(["ready", "complete", "done", "success", "succeed", "finish", "applied", "merged"]) {
                self = .done
            } else {
                self = .unknown
            }
        }
    }

    /// Parses `codex cloud list --json`: `{"tasks": [...], "cursor": ...}`.
    public static func parseList(_ data: Data) -> [Task]? {
        parsePage(data)?.tasks
    }

    /// The tasks plus the cursor for the next page, if any.
    public static func parsePage(_ data: Data) -> (tasks: [Task], cursor: String?)? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tasks = root["tasks"] as? [[String: Any]] else { return nil }
        let parsed: [Task] = tasks.compactMap { t in
            guard let id = t["id"] as? String else { return nil }
            return Task(
                id: id,
                url: (t["url"] as? String).flatMap(URL.init(string:)),
                title: (t["title"] as? String) ?? "Codex task",
                status: (t["status"] as? String) ?? "",
                updatedAt: (t["updated_at"] as? String) ?? "",
                environment: (t["environment_label"] as? String) ?? (t["environment_id"] as? String) ?? (t["environment"] as? String),
                summary: t["summary"] as? String
            )
        }
        let cursor = (root["cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (parsed, cursor)
    }

    /// Remembers each task's last phase and emits events for transitions:
    /// - a task seen working is announced as started, then gets a heartbeat on every poll (so
    ///   long tasks never look stale),
    /// - it's announced finished or failed only when seen moving out of working. Tasks that
    ///   were already finished when first seen stay quiet, and done → applied isn't news.
    public final class Tracker {
        private var seen: [String: Task] = [:]

        public init() {}

        /// Forget everything, e.g. when watching is switched off and on again.
        public func reset() {
            seen.removeAll()
        }

        /// Tasks we last saw working that weren't in `tasks` (pushed off the first page).
        public func activeIDs(missingFrom tasks: [Task]) -> Set<String> {
            let present = Set(tasks.map(\.id))
            return Set(seen.values.filter { $0.phase == .working && !present.contains($0.id) }.map(\.id))
        }

        public func update(with tasks: [Task], now: Date = Date()) -> [AgentEvent] {
            var events: [AgentEvent] = []
            for task in tasks {
                let previous = seen[task.id]?.phase
                seen[task.id] = task
                switch task.phase {
                case .working:
                    events.append(event(task, previous == .working ? .activity(tool: nil) : .promptSubmitted, now))
                case .done:
                    if previous == .working { events.append(event(task, .turnComplete(summary: task.summary), now)) }
                case .failed:
                    if previous == .working { events.append(event(task, .turnFailed(summary: task.summary ?? task.status), now)) }
                case .unknown:
                    break
                }
            }
            return events
        }

        private func event(_ task: Task, _ kind: AgentEventKind, _ now: Date) -> AgentEvent {
            AgentEvent(agent: .codexCloud, sessionID: task.id, cwd: task.environment, kind: kind, title: task.title, link: task.url, date: now)
        }
    }
}
