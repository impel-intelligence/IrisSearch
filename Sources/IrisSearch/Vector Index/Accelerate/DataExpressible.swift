//
//  DataExpressible.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/17/26.
//

protocol DataExpressible {
    func encode(into bytes: inout [UInt8])
    func encoded() -> [UInt8]
}
