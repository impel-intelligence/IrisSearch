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
    
    enum FaissError: Error {
        case invalidVectorDimension(size: Int, expected: Int)
    }

    private var embeddingProvider: EmbeddingProvider
    
    private var indexLocation: URL
    
    var cachedGlobalIndex: IDMap?
    
    var cachedDocumentIndices: [UUID: FlatIndex] = [:]
    
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
    
    public func removeDocument(documentID: UUID, pieceIDs: [Int]) throws {
        let indexURL = IndexLocation.document(uuid: documentID).filePath(in: indexLocation)
        try FileManager.default.removeItem(at: indexURL)
        
        try removeDocumentFromGlobalIndex(ids: pieceIDs)
        // Remove the cached index for the document.
        cachedDocumentIndices.removeValue(forKey: documentID)
    }
}

// MARK: Index Management
extension FaissIndex {    
    private func getGlobalIndex() throws -> IDMap {
        let indexURL = IndexLocation.global.filePath(in: indexLocation)
        
        // Quick exit with the cached global index
        if let cachedGlobalIndex {
            return cachedGlobalIndex
        }
        
        if FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)),
           let idMap = try? IDMap.from(indexURL.path(percentEncoded: false)) {
            cachedGlobalIndex = idMap
            return idMap
        } else {
            let coreIndex = try FlatIndex(d: embeddingProvider.dimension, metricType: .innerProduct)
            let idMap = try IDMap(subIndex: coreIndex)
            cachedGlobalIndex = idMap
            return idMap
        }
    }
    
    private func getDocumentIndex(uuid: UUID) throws -> FlatIndex {
        if let index = cachedDocumentIndices[uuid] {
            return index
        }
        
        // Use a flat index for single document indices as we do not need anything faster.
        let index = try FlatIndex(d: embeddingProvider.dimension, metricType: .innerProduct)
        cachedDocumentIndices[uuid] = index
        return index
    }
    
    private func removeDocumentFromGlobalIndex(ids: [Int]) throws {
        let indexURL = IndexLocation.global.filePath(in: indexLocation)
        
        let index: IDMap = try getGlobalIndex()
        
        // Delete all indices related to this document.
        try index.removeIds(ids)
        
        // Save the global index
        try index.saveToFile(indexURL.path(percentEncoded: false))
    }
    
    private func addDocumentToGlobalIndex(document: IrisDocument) throws {
        let indexURL = IndexLocation.global.filePath(in: indexLocation)
        
        // Create parallel arrays of embeddings and their corresponding document indices
        var embeddings: [[Float]] = []
        var ids: [Int] = []
        
        // For each embedding in the document, add it with the pieces's rowID as its ID
        // TODO: Remove empty embeddings dodge. It is here because images are not currently embedded.
        for piece in document.pieces where !piece.embeddings.isEmpty {
            guard let pieceID = piece.id else { continue }
            
            var embedding = piece.embeddings
            
            // Make sure that the dimensions for this vector are correct.
            guard embedding.count == self.embeddingProvider.dimension else {
                throw FaissError.invalidVectorDimension(size: embedding.count, expected: embeddingProvider.dimension)
            }
            
            faiss_fvec_renorm_L2(embeddingProvider.dimension, 1, &embedding)
            embeddings.append(embedding)
            ids.append(Int(pieceID))
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
        let index = try getDocumentIndex(uuid: document.uuid)
        
        // TODO: Remove empty embeddings dodge. It is here because images are not currently embedded.
        var embeddings = document.pieces.map(\.embeddings).filter({ !$0.isEmpty })
        
        // Make sure that all of the embeddings are the right size. Otherwise index.add will crash.
        for embedding in embeddings where embedding.count != embeddingProvider.dimension {
            throw FaissError.invalidVectorDimension(size: embedding.count, expected: embeddingProvider.dimension)
        }

        for index in 0..<embeddings.count {
            faiss_fvec_renorm_L2(embeddingProvider.dimension, 1, &embeddings[index])
        }

        // Check if the index needs to be trained, if so train.
        if !index.isTrained {
            try index.train(embeddings)
        }
        
        // Add the data to the index
        try index.add(embeddings)
        
        try index.saveToFile(indexURL.path(percentEncoded: false))
    }
}

// MARK: Searching
extension FaissIndex {
    
    /// Search the FaissIndex with an embedded query.
    /// - Parameters:
    ///   - query: The query embedding.
    ///   - k: The number of results to request.
    /// - Returns: The matching piece IDs paired with their cosine similarity  score.
    func search(query: [Float], kItems k: Int) throws -> [(id: Int, distance: Float)] {
        var query = query
        faiss_fvec_renorm_L2(embeddingProvider.dimension, 1, &query)

        let index: IDMap = try getGlobalIndex()

        let searchResults = try index.search([query], k: k)

        // We only ever pass a single query, so take the first row of each.
        let ids = searchResults.labels.first ?? []
        let distances = searchResults.distances.first ?? []
        
        // If there are not enough vectors faiss adds -1s to fill the array. Get rid of these in our map.
        return zip(ids, distances).filter { $0.0 != -1 }.map { (id: $0, distance: $1) }
    }
    
    func search(query: [Float], kItems k: Int, collection: UUID) throws -> [(id: Int, distance: Float)] {
        var query = query
        faiss_fvec_renorm_L2(embeddingProvider.dimension, 1, &query)
        
        let index: FlatIndex = try getDocumentIndex(uuid: collection)
        
        let searchResults = try index.search([query], k: k)
        
        // We only ever pass a single query, so take the first row of each.
        let ids = searchResults.labels.first ?? []
        let distances = searchResults.distances.first ?? []

        return zip(ids, distances).filter { $0.0 != -1 }.map { (id: $0, distance: $1) }
    }
    
//    private func translateLabels(labels: [Int], documents: [Document]) throws -> [Document] {
//        var resultingDocuments: [Document] = []
//
//        let documentsCount = documents.count
//        for index in labels where (index < documentsCount && index >= 0) {
//            resultingDocuments.append(documents[index])
//        }
//
//        return resultingDocuments
//    }
    
//    public func search(query: [Float], amount: Int) throws -> [Document] {
//        var query = query
//        faiss_fvec_renorm_L2(vectorDimensions, 1, &query)
//        
//        let indexPackage = try retrieveIndexAll()
//        let labels = try self.searchIndex(index: indexPackage.index, query: query, amount: amount)
//        let resultingDocuments = try translateLabels(labels: labels, documents: indexPackage.documents)
//        
//        return resultingDocuments
//    }
//    
//    public func search(in collection: Collection, query: [Float], amount: Int) throws -> [Document] {
//        var query = query
//        faiss_fvec_renorm_L2(vectorDimensions, 1, &query)
//        
//        let indexPackage = try retrieveIndex(for: collection)
//        let labels = try self.searchIndex(index: indexPackage.index, query: query, amount: amount)
//        let resultingDocuments = try translateLabels(labels: labels, documents: indexPackage.documents)
//        
//        return resultingDocuments
//    }
}
