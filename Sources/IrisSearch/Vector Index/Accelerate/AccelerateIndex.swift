//
//  IrisAccelerate.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/12/26.
//

#if os(Linux)
import Glibc
#else
import Darwin
#endif

import Foundation
import Accelerate
import IrisCommon

//final class AccelerateIndex: VectorIndex {
//    required init(indexLocation: URL, embeddingProvider: any IrisCommon.EmbeddingProvider) throws {
//        
//    }
//    
//    func addDocument(document: IrisDocument) throws {
//        
//    }
//    
//    func removeDocument(documentID: UUID, pieceIDs: [Int]) throws {
//        perAdded

//    }
//}
