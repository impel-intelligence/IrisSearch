////
////  bge.swift.swift
////  IrisSearch
////
////  Created by Taylor Lineman on 7/22/26.
////
//
//import NaturalLanguage
//import os
//import Synchronization
//import IrisCommon
//import Embeddings
//
//public final class bgeEmbedder: EmbeddingProvider, Sendable {
//    enum EmbeddingError: Error {
//        case couldNotCreateVector
//        case languageUnavailable(NLLanguage)
//    }
//
//    private let embeddingMutex: Mutex<NLContextualEmbedding>
//    private let language: IrisLanguage
//    public let dimension: Int
//    
//    required public convenience init() throws {
//        try self.init(language: .english)
//    }
//
//    public init(language: IrisLanguage) throws {
//        self.language = language
//
//    }
//    
//    public func embed(content: String) async throws -> [Double] {
//        // Serialize access: the underlying model is not safe to call concurrently.
//        // load model and tokenizer from Hugging Face
////        let modelBundle = try await Bert.loadModelBundle(
////            from: "sentence-transformers/all-MiniLM-L6-v2"
////        )
////
////        // encode text
////        let encoded = try modelBundle.encode("The cat is black")
////        let result = await encoded.cast(to: Float.self).shapedArray(of: Float.self).scalars
////
////        // print result
//
//    }
//}
