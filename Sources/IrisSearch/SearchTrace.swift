//
//  SearchTrace.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/23/26.
//

import Foundation

/// Identifies which retrieval channel surfaced a document during a search.
///
/// A single ``search(query:nItems:ranking:)`` call queries several independent channels and fuses
/// their results. Once fused, the per-channel provenance is normally lost; ``SearchTrace`` records it
/// for debugging.
public enum RetrievalChannel: String, Sendable, CaseIterable {
    /// FAISS vector similarity over the text index.
    case semanticText
    /// FTS5 full-text search over the `documents` table (title & description).
    case syntacticDocument
    /// FTS5 full-text search over the `document_pieces` table (chunked body text).
    case syntacticDocumentPiece

    /// A short label suitable for debug output.
    public var label: String {
        switch self {
        case .semanticText: return "semantic"
        case .syntacticDocument: return "fts-doc"
        case .syntacticDocumentPiece: return "fts-piece"
        }
    }
}

/// One retrieval channel's contribution to a single document.
public struct ChannelHit: Sendable {
    /// The channel that surfaced the document.
    public let channel: RetrievalChannel
    /// Zero-based position of the document within this channel's own ranked output (lower is better).
    public let rank: Int
    /// The raw score the channel reported: FTS5 BM25 rank for syntactic channels, vector distance for the semantic channel.
    public let score: Double
    /// For ``RetrievalChannel/syntacticDocumentPiece``, the id of the piece that matched. `nil` for other channels.
    public let matchedPieceID: Int?

    public init(channel: RetrievalChannel, rank: Int, score: Double, matchedPieceID: Int? = nil) {
        self.channel = channel
        self.rank = rank
        self.score = score
        self.matchedPieceID = matchedPieceID
    }
}

/// The provenance for one document in a search result: which channels found it, and where it landed after fusion.
public struct DocumentTrace: Sendable, Identifiable {
    /// The `documents` table row id.
    public let id: Int
    /// The document's stable UUID (matches the originating `File`).
    public let uuid: UUID
    /// The document title.
    public let title: String
    /// Zero-based position in the fused ranking.
    public let fusedRank: Int
    /// Every channel that surfaced this document, with each channel's own rank & score.
    public let hits: [ChannelHit]

    /// The distinct channels that surfaced this document.
    public var channels: [RetrievalChannel] {
        hits.map(\.channel)
    }
}

/// A full debug trace of a single ``IrisDB`` search, capturing per-document retrieval-channel provenance.
public struct SearchTrace: Sendable {
    /// The query text that was searched.
    public let query: String
    /// The fusion algorithm used to combine channels.
    public let ranking: FusionAlgorithm
    /// The per-channel candidate limit used for this search.
    public let searchLimit: Int
    /// The number of documents actually returned to the caller (the fused candidates are truncated to this many).
    public let returnedCount: Int
    /// Every resolved candidate document, in fused-rank order. This may be longer than `returnedCount`.
    public let documents: [DocumentTrace]
}

extension SearchTrace: CustomStringConvertible {
    public var description: String {
        var lines: [String] = []
        lines.append("SearchTrace(query: \"\(query)\", ranking: \(ranking), searchLimit: \(searchLimit), returned: \(returnedCount)/\(documents.count) candidates)")

        for document in documents {
            let marker = document.fusedRank < returnedCount ? "✓" : " "
            lines.append("  [\(marker)] #\(document.fusedRank) \(document.title) (id: \(document.id), uuid: \(document.uuid))")

            // Show each contributing channel in a stable order.
            for channel in RetrievalChannel.allCases {
                guard let hit = document.hits.first(where: { $0.channel == channel }) else { continue }
                let pieceSuffix = hit.matchedPieceID.map { " piece=\($0)" } ?? ""
                lines.append("        - \(channel.label): rank=\(hit.rank) score=\(String(format: "%.4f", hit.score))\(pieceSuffix)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
