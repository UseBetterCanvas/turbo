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
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tasks = root["tasks"] as? [[String: Any]] else { return nil }
        return tasks.compactMap { t in
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
    }

    /// Remembers what it saw last time and emits events only for changes. The first poll
    /// announces tasks that are still working (so they appear on the board) but not ones that
    /// finished before Turbo started.
    public final class Tracker {
        private var seen: [String: Task] = [:]
        private var primed = false

        public init() {}

        public func update(with tasks: [Task], now: Date = Date()) -> [AgentEvent] {
            var events: [AgentEvent] = []
            for task in tasks {
                let previous = seen[task.id]
                seen[task.id] = task
                guard previous?.status != task.status || previous == nil else {
                    // Same status but newer timestamp while working: count it as a beat.
                    if task.phase == .working, previous?.updatedAt != task.updatedAt {
                        events.append(event(task, .activity(tool: nil), now))
                    }
                    continue
                }
                switch task.phase {
                case .working:
                    events.append(event(task, .promptSubmitted, now))
                case .done:
                    if primed { events.append(event(task, .turnComplete(summary: task.summary), now)) }
                case .failed:
                    if primed { events.append(event(task, .turnComplete(summary: "Failed: " + (task.summary ?? task.status)), now)) }
                case .unknown:
                    break
                }
            }
            primed = true
            return events
        }

        private func event(_ task: Task, _ kind: AgentEventKind, _ now: Date) -> AgentEvent {
            AgentEvent(agent: .codexCloud, sessionID: task.id, cwd: task.environment, kind: kind, title: task.title, link: task.url, date: now)
        }
    }
}
