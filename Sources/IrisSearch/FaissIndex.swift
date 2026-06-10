//
//  FaissIndex.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import Foundation
import SwiftFaiss
import SwiftFaissC

final class FaissIndex {
    private static let indexExtension = "index"
    
    enum IndexLocation {
        case global
        case document(uuid: UUID)
        
        func filePath(in location: URL) -> URL {
            switch self {
            case .global:
                return location.appending(component: "global").appendingPathExtension(FaissIndex.indexExtension)
            case .document(let uuid):
                return location.appending(component: uuid.uuidString).appendingPathExtension(FaissIndex.indexExtension)
            }
        }
    }
    
    private var embeddingProvider: EmbeddingProvider
    
    private var indexLocation: URL
    
    init(indexLocation: URL, embeddingProvider: EmbeddingProvider) throws {
        self.indexLocation = indexLocation
        self.embeddingProvider = embeddingProvider
        try initializeDB()
    }
    
    private func initializeDB() throws {
        if !FileManager.default.fileExists(atPath: indexLocation.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: indexLocation, withIntermediateDirectories: true)
        }
    }
    
    public func addDocument(document: IrisDocument) throws {
        try refreshIndex(for: document)
        try addDocumentToGlobalIndex(document: document)
    }
    
    public func removeDocument(document: IrisDocument) throws {
        let indexURL = IndexLocation.document(uuid: document.uuid).filePath(in: indexLocation)
        try FileManager.default.removeItem(at: indexURL)
        
        try removeDocumentFromGlobalIndex(document: document)
    }
    
}

// MARK: Index Management
extension FaissIndex {
    private func getGlobalIndex() throws -> IDMap {
        let indexURL = IndexLocation.global.filePath(in: indexLocation)
        
        if FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)),
           let flatIndex = try? IDMap.from(indexURL.path(percentEncoded: false)) {
            return flatIndex
        } else {
            let coreIndex = try FlatIndex(d: embeddingProvider.dimension, metricType: .l2)
            return try IDMap(subIndex: coreIndex)
        }
    }
    
    private func removeDocumentFromGlobalIndex(document: IrisDocument) throws {
        let indexURL = IndexLocation.global.filePath(in: indexLocation)
        
        guard let documentID = document.id else { throw IrisDBError.documentNotFound }
        
        let index: IDMap = try getGlobalIndex()
        
        // Delete all indices related to this document.
        try index.removeIds([Int(documentID)])
        
        // Save the global index
        try index.saveToFile(indexURL.path(percentEncoded: false))
    }
    
    private func addDocumentToGlobalIndex(document: IrisDocument) throws {
        let indexURL = IndexLocation.global.filePath(in: indexLocation)
        
        guard let documentID = document.id else { throw IrisDBError.documentNotFound }
        
        let index: IDMap = try getGlobalIndex()
        
        var embeddings: [[Float]] = []
        var ids: [Int] = []
        
        for embedding in document.embeddings {
            embeddings.append(embedding)
            ids.append(Int(documentID))
        }
        
        // Check if the index needs to be trained, if so train.
        if !index.isTrained {
            try index.train(embeddings)
        }
        
        // Add the data to the index with their corresponding IDs
        try index.add(embeddings, ids: ids)
        // Save the global index
        try index.saveToFile(indexURL.path(percentEncoded: false))
    }
    
    private func refreshGlobalIndex(documents: [IrisDocument]) throws {
        let indexURL = IndexLocation.global.filePath(in: indexLocation)
                
        // Create parallel arrays of embeddings and their corresponding document indices
        var embeddings: [[Float]] = []
        var ids: [Int] = []
        
        for document in documents {
            guard let documentID = document.id else { continue }
            // For each embedding in the document, add it with the document's rowID as its ID
            for embedding in document.embeddings {
                embeddings.append(embedding)
                ids.append(Int(documentID))
            }
        }
        
        let index: IDMap = try getGlobalIndex()
        
        // Check if the index needs to be trained, if so train.
        if !index.isTrained {
            try index.train(embeddings)
        }
        
        // Add the data to the index with their corresponding IDs
        try index.add(embeddings, ids: ids)
        // Save the global index
        try index.saveToFile(indexURL.path(percentEncoded: false))
    }
    
    private func refreshIndex(for document: IrisDocument) throws {
        let indexURL = IndexLocation.document(uuid: document.uuid).filePath(in: indexLocation)
        
        // If an index already exists, remove it so we can create a new one.
        if FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: indexURL)
        }
        
        // Use a flat index for single document indices as we do not need anything faster.
        let index = try FlatIndex(d: embeddingProvider.dimension, metricType: .l2)
        
        // Check if the index needs to be trained, if so train.
        if !index.isTrained {
            try index.train(document.embeddings)
        }
        
        // Add the data to the index
        try index.add(document.embeddings)
        
        try index.saveToFile(indexURL.path(percentEncoded: false))
    }
}

