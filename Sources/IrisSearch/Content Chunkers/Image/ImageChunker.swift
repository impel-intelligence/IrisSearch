//
//  ImageChunker.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import Foundation

public protocol ImageChunker {
    init()

    func chunk(images: [Data], chunkDimensions: CGRect) -> [Data]
}
