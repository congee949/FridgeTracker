import Foundation
import SwiftData
@testable import FridgeTracker

/// Shared SwiftData fixture for unit tests.
///
/// One in-memory `ModelContainer` is created per test process and kept alive for the whole run.
/// This matters on Xcode 26 / iOS 26 simulators where SwiftData traps (EXC_BREAKPOINT) if:
///   - the container is deallocated while a `ModelContext` from it is still in use (a dangling
///     context — the failure mode if each call created and dropped its own container), or
///   - many containers for the same schema are created in one process.
/// A single retained container avoids both. `makeContext()` wipes all model data first so every
/// test still starts from a clean, isolated store.
@MainActor
enum TestModelContainer {
    private static var sharedContainer: ModelContainer?

    /// The process-wide in-memory container holding the full app schema (created once).
    static func make() throws -> ModelContainer {
        if let sharedContainer { return sharedContainer }
        let schema = Schema([FoodItem.self, FoodDispositionRecord.self, ReplenishmentItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        sharedContainer = container
        return container
    }

    /// A clean main context for a test: shares the one container, autosave disabled, with all
    /// model data cleared so tests don't see each other's objects.
    static func makeContext() throws -> ModelContext {
        let context = try make().mainContext
        context.autosaveEnabled = false
        context.rollback() // drop any unsaved objects left by a previous test
        try context.delete(model: FoodItem.self)
        try context.delete(model: FoodDispositionRecord.self)
        try context.delete(model: ReplenishmentItem.self)
        try context.save()
        return context
    }
}
