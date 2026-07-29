//
//  CoreMLRunner.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/22/26.
//

import CoreML
import IrisCommon
import Synchronization

enum CoreMLRunnerInitError: Error {
    case missingCompiledModel
    case missingVocab
    case missingConfig
}

enum CoreMLRunnerError: Error {
    case noEmbeddingsInOutput
}

public final class CoreMLEmbedder: Sendable, EmbeddingProvider {
    let model: Mutex<MLModel>
    let tokenizer: BERTWordPieceTokenizer
    let configuration: ModelConfiguration
    
    public let dimension: Int

    public init(modelDirectory: URL) throws {
        // Make sure we can find the .mlmodelc and the vocab.txt files we need.
        let (modelURL, vocabURL, configURL) = try CoreMLEmbedder.validateDirectory(modelDirectory)
        
        let modelConfiguration = MLModelConfiguration()
        modelConfiguration.computeUnits = .all // Utilizes CPU, GPU, and Neural Engine (ANE)
        
        let model = try MLModel(contentsOf: modelURL, configuration: modelConfiguration)
        self.model = Mutex(model)
        
        self.configuration = try ModelConfiguration.load(from: configURL)
        self.dimension = configuration.dimensions
        
        // Match the normalizer configuration of many BERT models (from huggingface-transformers)
        let normalizer = BertNormalizer(
            cleanText: configuration.cleanText,
            handleChineseCharacters: configuration.handleChineseCharacters,
            stripAccents: configuration.stripAccents,
            lowercase: configuration.lowercase
        )
        
        self.tokenizer = try BERTWordPieceTokenizer(
            vocabURL: vocabURL,
            normalizer: normalizer,
            maximumInputCharactersPerWord: configuration.maximumInputCharactersPerWord
        )
    }

    private static func validateDirectory(_ directory: URL) throws -> (model: URL, vocab: URL, config: URL) {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentTypeKey])
        let models = contents.filter { $0.pathExtension == "mlmodelc" }
        
        // Can also take uncompiled versions and compile them: "mlpackage" "mlmodel": try MLModel.compileModel(at: _)
        guard let modelURL = models.first else {
            throw CoreMLRunnerInitError.missingCompiledModel
        }
        
        let vocabURL = directory.appendingPathComponent("vocab", conformingTo: .plainText)
        
        guard FileManager.default.fileExists(atPath: vocabURL.path(percentEncoded: false)) else {
            throw CoreMLRunnerInitError.missingVocab
        }
        
        let configURL = directory.appendingPathComponent("config", conformingTo: .json)
        
        guard FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)) else {
            throw CoreMLRunnerInitError.missingConfig
        }
        
        return (modelURL, vocabURL, configURL)
    }
    
    public func embed(content: String) throws -> [Double] {
        // Since Model can not be used by multiple threads at once, use a lock to wait for the w
        return try model.withLock { model in
            let tokens = tokenizer.encode(content, maxLength: self.dimension)
            
            let shape: [Int] = [1, tokens.inputIDs.count]

            let inputIDs = MLShapedArray<Int32>(scalars: tokens.inputIDs, shape: shape)
            let attentionMask = MLShapedArray<Int32>(scalars: tokens.attentionMask, shape: shape)
            // BERT has a token type of either 0 or 1, depending on if the tokens are part of the first or second sentence. Since we always have a single sentence we just set all the IDs to zero.
            let tokenTypeIDs = MLShapedArray<Int32>(repeating: 0, shape: shape)

            let features = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(shapedArray: inputIDs),
                "attention_mask": MLFeatureValue(shapedArray: attentionMask),
                "token_type_ids": MLFeatureValue(shapedArray: tokenTypeIDs)
            ])

            let output = try model.prediction(from: features)
            
            guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue else {
                throw CoreMLRunnerError.noEmbeddingsInOutput
            }
            
            #if arch(arm64)
            let rawEmbeddings = MLShapedArray<Float16>(embedding)

            return rawEmbeddings.scalars.map(Double.init)
            #else
            let rawEmbeddings = MLShapedArray<Float>(embedding)

            return rawEmbeddings.scalars.map(Double.init)
            #endif
        }
    }
    
    public func embedQuery(content: String) async throws -> [Double] {
        let newContent = (configuration.searchPrefix ?? "") + content
        return try embed(content: newContent)
    }
}
