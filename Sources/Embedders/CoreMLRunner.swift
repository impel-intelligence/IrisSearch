//
//  CoreMLRunner.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/22/26.
//

import CoreML

class CoreMLRunner {
    
    
    init(compiledModel: URL) {
        let config = MLModelConfiguration()
        config.computeUnits = .all // Utilizes CPU, GPU, and Neural Engine (ANE)
        
    }
}
