import NIOPosix

/// Runs `body` with a one-thread client event loop group, and shuts it down after.
func withClientGroup<T>(_ body: (MultiThreadedEventLoopGroup) async throws -> T) async throws -> T {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let result = try await body(group)
        try await group.shutdownGracefully()
        return result
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }
}
