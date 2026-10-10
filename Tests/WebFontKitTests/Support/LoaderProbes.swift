import Foundation
@testable import WebFontKit

extension WebFonts {
    var startedWarmUps: Int {
        state.withLock { $0.warmUpsStarted }
    }

    /// Awaits the family's resolve, fetch, draining and commit tasks, re-reading until no
    /// new one appears. Work that waits on a caller's own task is left to that caller.
    func quiesce(family: String) async {
        var awaited: Set<Task<Void, Never>> = []
        var awaitedCommits: Set<Task<CommitOutcome, Never>> = []
        while true {
            let (tasks, commits) = state.withLock { state -> ([Task<Void, Never>], [Task<CommitOutcome, Never>]) in
                let jobs = state.jobs.filter { $0.key.family == family }.values
                let resolves = state.resolves.values.filter { $0.keys.contains { $0.family == family } }
                let draining = state.draining.values.filter { $0.key.family == family }
                return (jobs.compactMap(\.task) + resolves.compactMap(\.task) + draining.map(\.task), jobs.compactMap(\.commit))
            }
            let newTasks = tasks.filter { !awaited.contains($0) }
            let newCommits = commits.filter { !awaitedCommits.contains($0) }
            if newTasks.isEmpty && newCommits.isEmpty { return }
            for task in newTasks { await task.value }
            for commit in newCommits { _ = await commit.value }
            awaited.formUnion(newTasks)
            awaitedCommits.formUnion(newCommits)
        }
    }
}
