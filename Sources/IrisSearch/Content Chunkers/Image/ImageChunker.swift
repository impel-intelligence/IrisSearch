//
//  ImageChunker.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import Foundation

protocol ImageChunker {
    func chunk(images: [Data], chunkDimensions: CGRect) -> [String]
}
