import CoreData

extension WorkoutDataStorage {
    /// Preserve the explicit historical mappings, then let Core Data infer the additive v4 → current migration.
    public static func prepareSessionMigration(_ description: NSPersistentStoreDescription) throws {
        guard description.type == NSSQLiteStoreType, let url = description.url,
              FileManager.default.fileExists(atPath: url.path) else { return }
        let options = description.options
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url, options: options)
        let bundle = Bundle(for: WorkoutDataStorage.self)
        guard let directory = bundle.url(forResource: "WorkoutData", withExtension: "momd"),
              let v4 = NSManagedObjectModel(contentsOf: directory.appendingPathComponent("WorkoutData v4.mom")) else {
            throw CocoaError(.fileReadUnknown)
        }
        if model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) ||
            v4.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) { return }
        // v5 and later only add metadata and can use inferred migration directly.
        if let source = NSManagedObjectModel.mergedModel(from: [bundle], forStoreMetadata: metadata),
           source.entitiesByName["WorkoutSessionState"] != nil { return }
        guard let source = NSManagedObjectModel.mergedModel(from: [bundle], forStoreMetadata: metadata),
              let mapping = NSMappingModel(from: [bundle], forSourceModel: source, destinationModel: v4) else {
            throw CocoaError(.migrationMissingMappingModel)
        }
        let temporaryDirectory = url.deletingLastPathComponent().appendingPathComponent("migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let temporaryURL = temporaryDirectory.appendingPathComponent("WorkoutData.sqlite")
        let manager = NSMigrationManager(sourceModel: source, destinationModel: v4)
        try manager.migrateStore(from: url, sourceType: NSSQLiteStoreType, options: options,
            with: mapping, toDestinationURL: temporaryURL, destinationType: NSSQLiteStoreType, destinationOptions: nil)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v4)
        try coordinator.replacePersistentStore(at: url, destinationOptions: options,
            withPersistentStoreFrom: temporaryURL, sourceOptions: nil, ofType: NSSQLiteStoreType)
    }
}
