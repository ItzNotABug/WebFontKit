import Foundation
@testable import WebFontKit

extension WebFonts {
    var startedWarmUps: Int {
        state.withLock { $0.warmUpsStarted }
    }

    /// Returns once the family has no resolve, style task or commit in flight.
    func quiesce(family: String) async {
        while true {
            let (tasks, commits) = state.withLock { state -> ([Task<Void, Never>], [Task<CommitOutcome, Never>]) in
                let jobs = state.jobs.filter { $0.key.family == family }
                let resolves = state.resolves.values.filter { $0.keys.contains { $0.family == family } }
                return (jobs.values.compactMap(\.task) + resolves.compactMap(\.task), jobs.values.compactMap(\.commit))
            }
            if tasks.isEmpty && commits.isEmpty { return }
            for task in tasks { await task.value }
            for commit in commits { _ = await commit.value }
            let remaining = state.withLock { state in
                state.jobs.keys.contains { $0.family == family } || state.resolves.values.contains { $0.keys.contains { $0.family == family } }
            }
            if !remaining { return }
            await Task.yield()
        }
    }
}
