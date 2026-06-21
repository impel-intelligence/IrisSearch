//
//  KeyedExecutor.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/20/26.
//

import Foundation


/// <#Description#>
public actor KeyedExecutor<Key: Hashable & Sendable>  {
    /// <#Description#>
    var executionChainTails: [Key: Task<Void, Never>] = [:]

    public init() {}
    
    @discardableResult
    public func run<Success: Sendable>(_ key: Key, _ operation: @Sendable @escaping () async throws -> Success) async throws -> Success {
        return try await submit(key, operation).value
    }
    
    /// <#Description#>
    /// - Parameters:
    ///   - key: <#key description#>
    ///   - operation: <#operation description#>
    /// - Returns: <#description#>
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
