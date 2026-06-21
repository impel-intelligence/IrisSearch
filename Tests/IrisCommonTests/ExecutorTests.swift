//
//  ExecutorTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/21/26.
//

import Testing
@testable import IrisCommon
import Foundation

@Suite struct ExecutorTests {
    @Test()
    func testExecutor() async throws {
        let executor: KeyedExecutor<UUID> = KeyedExecutor()
        
        let run1 = UUID()
        
        let x = try await executor.run(run1) {
            for i in 0..<100 {
                print("1: \(i)")
            }
            return 100
        }
        
        print("1 - Result: \(x)")
        
        let run2 = UUID()
        let y = try await executor.run(run2) {
            for i in 0..<1000 {
                print("2: \(i)")
            }
            return 1000
        }
        
        print("2 - Result: \(y)")
        
        let z = try await executor.run(run1) {
            for i in 0..<100 {
                print("1-2: \(i)")
            }
            return 100
        }
        
        print("1 - 2 - Result: \(z)")
    }
}
