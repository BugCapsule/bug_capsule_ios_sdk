#if canImport(CoreData)
    import CoreData

    /// Core Data spans (`db` op) under the active span. Explicit wrappers,
    /// no swizzling: call them where you fetch and save.
    ///
    /// ```swift
    /// let items = try context.bugCapsuleFetch(CartItem.fetchRequest())
    /// try context.bugCapsuleSave()
    /// ```
    extension NSManagedObjectContext {
        public func bugCapsuleFetch<T: NSFetchRequestResult>(_ request: NSFetchRequest<T>) throws -> [T] {
            let span = BugCapsule.activeSpan?.startChild(
                op: "db.sql.query", description: "FETCH \(request.entityName ?? "entity")")
            span?.setData("db.system", "core_data")
            do {
                let result = try fetch(request)
                span?.setData("read_count", result.count)
                span?.finish()
                return result
            } catch {
                span?.finish(status: .internalError)
                throw error
            }
        }

        public func bugCapsuleSave() throws {
            guard hasChanges else { return }
            let span = BugCapsule.activeSpan?.startChild(op: "db.sql.query", description: "SAVE")
            span?.setData("db.system", "core_data")
            span?.setData("inserted", insertedObjects.count)
            span?.setData("updated", updatedObjects.count)
            span?.setData("deleted", deletedObjects.count)
            do {
                try save()
                span?.finish()
            } catch {
                span?.finish(status: .internalError)
                throw error
            }
        }
    }
#endif
