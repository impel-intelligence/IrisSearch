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
    
    var cachedDocumentIndices: [UUID: IDMap] = [:]
    
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
    private func cache(location: IndexLocation, index: IDMap) {
        switch location {
        case .document(let uuid):
            cachedDocumentIndices[uuid] = index
        case .global:
            cachedGlobalIndex = index
        }
    }
    
    private func getCached(location: IndexLocation) -> IDMap? {
        // Quick exit with cached indexes
        switch location {
        case .document(let uuid):
            if let index = cachedDocumentIndices[uuid] {
                return index
            }
        case .global:
            return cachedGlobalIndex
        }
        
        return nil
    }
    
    private func getIndex(for location: IndexLocation) throws -> IDMap {
        let indexURL = location.filePath(in: indexLocation)
        
        if let cached = getCached(location: location) {
            return cached
        }
        
        if FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)),
           let idMap = try? IDMap.from(indexURL.path(percentEncoded: false)) {
            cache(location: location, index: idMap)
            return idMap
        } else {
            let coreIndex = try FlatIndex(d: embeddingProvider.dimension, metricType: .innerProduct)
            let idMap = try IDMap(subIndex: coreIndex)
            cache(location: location, index: idMap)
            return idMap
        }

    }

    private func removeDocumentFromGlobalIndex(ids: [Int]) throws {
        let indexURL = IndexLocation.global.filePath(in: indexLocation)
        
        let index: IDMap = try getIndex(for: .global)
        
        // Delete all indices related to this document.
        try index.removeIds(ids)
        
        // Save the global index
        try index.saveToFile(indexURL.path(percentEncoded: false))
    }
    
    private func addDocumentToGlobalIndex(document: IrisDocument) throws {
        let indexURL = IndexLocation.global.filePath(in: indexLocation)
        
        try add(pieces: document.pieces, to: IndexLocation.global)
    }
    
    private func refreshIndex(for document: IrisDocument) throws {
        let indexURL = IndexLocation.document(uuid: document.uuid).filePath(in: indexLocation)
        
        // If an index already exists, remove it so we can create a new one.
        if FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: indexURL)
        }
                
        try add(pieces: document.pieces, to: IndexLocation.document(uuid: document.uuid))
    }
    
    private func add(pieces: [DocumentPiece], to location: IndexLocation) throws {
        // Create parallel arrays of embeddings and their corresponding document indices
        var embeddings: [[Float]] = []
        var ids: [Int] = []
        
        // For each embedding in the document, add it with the pieces's rowID as its ID
        // TODO: Remove empty embeddings dodge. It is here because images are not currently embedded.
        for piece in pieces where !piece.embeddings.isEmpty {
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
        
        let index = try getIndex(for: location)

        // Check if the index needs to be trained, if so train.
        if !index.isTrained {
            try index.train(embeddings)
        }
        
        // Add the data to the index with their corresponding IDs
        try index.add(embeddings, ids: ids)
        
        // Save the index to a file
        let indexURL = location.filePath(in: indexLocation)

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

        let index: IDMap = try getIndex(for: .global)

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
        
        let index: IDMap = try getIndex(for: .document(uuid: collection))
        
        let searchResults = try index.search([query], k: k)
        
        // We only ever pass a single query, so take the first row of each.
        let ids = searchResults.labels.first ?? []
        let distances = searchResults.distances.first ?? []

        return zip(ids, distances).filter { $0.0 != -1 }.map { (id: $0, distance: $1) }
    }
}
