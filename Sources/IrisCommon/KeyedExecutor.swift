//
//  KeyedExecutor.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/20/26.
//

import Foundation

/// An execution manager that serializes tasks by key.
///
/// Tasks submitted with the same key, complete in submission order without any overlap. Tasks with different keys execute concurrently.
public actor KeyedExecutor<Key: Hashable & Sendable>  {
    /// A dictionary tracking the most recently submitted task per key. Each task in this dictionary waits on any previous tasks submitted with the same key. This behavior stacks, creating a chain of waiting tasks, where the tail is tracked in this structure.
    var executionChainTails: [Key: Task<Void, Never>] = [:]

    public init() {}
    
    /// Run and immediately await the value of an operation.
    /// - Parameters:
    ///   - key: The key to submit the operation with.
    ///   - operation: The operation to run. Will wait for other operations with the same key to complete before executing.
    /// - Returns: The `Success` output of the operation.
    @discardableResult
    public func run<Success: Sendable>(_ key: Key, _ operation: @Sendable @escaping () async throws -> Success) async throws -> Success {
        return try await submit(key, operation).value
    }
    
    /// Submit an operation to the executor, but do not wait for it to return.
    /// - Parameters:
    ///   - key: The key to submit the operation with.
    ///   - operation: The operation to run. Will wait for other operations with the same key to complete before executing.
    /// - Returns: The task that the given operation will run on. To wait for the value, you can await this task's value.
    @discardableResult
    public func submit<Success: Sendable>(_ key: Key, _ operation: @Sendable @escaping () async throws -> Success) -> Task<Success, Error> {
        // Retrieve the previous tail. The new tail is updated later in the function. Since this is an actor and there are no awaits between here and the setting, the update is atomic.
        let previous = executionChainTails[key]
        
        // The task that actually runs the user's operation. Will either return or throw but must be try awaited in the call site.
        let resultTask = Task<Success, Error> {
            // Join the previous task in this chain and wait for it to complete. Once it is done, we can run our own operation. This chains, as more tasks are added, each task waits for the task in front of it in line.
            _ = await previous?.result
            return try await operation()
        }
        
        // A type erased mini-task that can be set as the execution tail. Since the caller will handle the result and errors, we drop them here.
        let completion = Task<Void, Never> {
            _ = try? await resultTask.value
        }
        
        // Update the execution tail, so future operations queued for this key will need to await the operation that was just submitted.
        executionChainTails[key] = completion
        
        // Cleanup task. Once the execution of resultTask finishes, this will check to see if any other tasks have been added to the chain. If no other tasks have, the chain will be removed.
        Task {
            _ = await completion.result
            if executionChainTails[key] == completion {
                executionChainTails[key] = nil
            }
        }
        
        return resultTask
    }

}
