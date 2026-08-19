
| dims | matrix | vectors | `vDSP_mmul` | `vDSP_dotpr` | faster | by |
| ---: | ---: | ---: | ---: | ---: | :--- | ---: |
| 64 | 1 MiB | 4,096 | 0.011 ms | 0.029 ms | `mmul` | 2.64× |
| 64 | 4 MiB | 16,384 | 0.058 ms | 0.114 ms | `mmul` | 1.97× |
| 64 | 16 MiB | 65,536 | 0.116 ms | 0.458 ms | `mmul` | 3.95× |
| 64 | 48 MiB | 196,608 | 0.466 ms | 1.379 ms | `mmul` | 2.96× |
| 64 | 96 MiB | 393,216 | 0.962 ms | 2.774 ms | `mmul` | 2.88× |
| 64 | 256 MiB | 1,048,576 | 2.501 ms | 7.559 ms | `mmul` | 3.02× |
| 128 | 1 MiB | 2,048 | 0.014 ms | 0.025 ms | `mmul` | 1.79× |
| 128 | 4 MiB | 8,192 | 0.056 ms | 0.103 ms | `mmul` | 1.84× |
| 128 | 16 MiB | 32,768 | 0.295 ms | 0.414 ms | `mmul` | 1.40× |
| 128 | 48 MiB | 98,304 | 0.915 ms | 1.247 ms | `mmul` | 1.36× |
| 128 | 96 MiB | 196,608 | 1.861 ms | 2.506 ms | `mmul` | 1.35× |
| 128 | 256 MiB | 524,288 | 5.652 ms | 6.723 ms | `mmul` | 1.19× |
| 192 | 1 MiB | 1,365 | 0.013 ms | 0.025 ms | `mmul` | 1.92× |
| 192 | 4 MiB | 5,461 | 0.050 ms | 0.102 ms | `mmul` | 2.04× |
| 192 | 16 MiB | 21,845 | 0.282 ms | 0.418 ms | `mmul` | 1.48× |
| 192 | 48 MiB | 65,536 | 0.847 ms | 1.229 ms | `mmul` | 1.45× |
| 192 | 96 MiB | 131,072 | 1.758 ms | 2.476 ms | `mmul` | 1.41× |
| 192 | 256 MiB | 349,525 | 5.159 ms | 7.171 ms | `mmul` | 1.39× |
| 256 | 1 MiB | 1,024 | 0.011 ms | 0.025 ms | `mmul` | 2.27× |
| 256 | 4 MiB | 4,096 | 0.044 ms | 0.102 ms | `mmul` | 2.32× |
| 256 | 16 MiB | 16,384 | 0.282 ms | 0.407 ms | `mmul` | 1.44× |
| 256 | 48 MiB | 49,152 | 0.964 ms | 1.228 ms | `mmul` | 1.27× |
| 256 | 96 MiB | 98,304 | 1.896 ms | 2.473 ms | `mmul` | 1.30× |
| 256 | 256 MiB | 262,144 | 5.246 ms | 6.619 ms | `mmul` | 1.26× |
| 320 | 1 MiB | 819 | 0.011 ms | 0.025 ms | `mmul` | 2.27× |
| 320 | 4 MiB | 3,276 | 0.044 ms | 0.101 ms | `mmul` | 2.30× |
| 320 | 16 MiB | 13,107 | 0.322 ms | 0.409 ms | `mmul` | 1.27× |
| 320 | 48 MiB | 39,321 | 1.120 ms | 1.220 ms | tie | 0.92× |
| 320 | 96 MiB | 78,643 | 2.838 ms | 2.557 ms | `dotpr` | 1.11× |
| 320 | 256 MiB | 209,715 | 7.590 ms | 6.854 ms | `dotpr` | 1.11× |
| 384 | 1 MiB | 682 | 0.010 ms | 0.025 ms | `mmul` | 2.50× |
| 384 | 4 MiB | 2,730 | 0.041 ms | 0.101 ms | `mmul` | 2.46× |
| 384 | 16 MiB | 10,922 | 0.330 ms | 0.407 ms | `mmul` | 1.23× |
| 384 | 48 MiB | 32,768 | 1.188 ms | 1.219 ms | tie | 0.97× |
| 384 | 96 MiB | 65,536 | 2.769 ms | 2.558 ms | tie | 1.08× |
| 384 | 256 MiB | 174,762 | 7.350 ms | 6.838 ms | tie | 1.07× |
| 512 | 1 MiB | 512 | 0.010 ms | 0.025 ms | `mmul` | 2.50× |
| 512 | 4 MiB | 2,048 | 0.038 ms | 0.105 ms | `mmul` | 2.76× |
| 512 | 16 MiB | 8,192 | 0.425 ms | 0.423 ms | tie | 1.00× |
| 512 | 48 MiB | 24,576 | 1.698 ms | 1.266 ms | `dotpr` | 1.34× |
| 512 | 96 MiB | 49,152 | 4.440 ms | 2.549 ms | `dotpr` | 1.74× |
| 512 | 256 MiB | 131,072 | 11.931 ms | 6.801 ms | `dotpr` | 1.75× |
| 768 | 1 MiB | 341 | 0.010 ms | 0.026 ms | `mmul` | 2.60× |
| 768 | 4 MiB | 1,365 | 0.036 ms | 0.105 ms | `mmul` | 2.92× |
| 768 | 16 MiB | 5,461 | 0.360 ms | 0.422 ms | `mmul` | 1.17× |
| 768 | 48 MiB | 16,384 | 1.417 ms | 1.268 ms | `dotpr` | 1.12× |
| 768 | 96 MiB | 32,768 | 3.351 ms | 2.548 ms | `dotpr` | 1.32× |
| 768 | 256 MiB | 87,381 | 8.940 ms | 6.869 ms | `dotpr` | 1.30× |
| 1024 | 1 MiB | 256 | 0.009 ms | 0.026 ms | `mmul` | 2.89× |
| 1024 | 4 MiB | 1,024 | 0.038 ms | 0.105 ms | `mmul` | 2.76× |
| 1024 | 16 MiB | 4,096 | 0.389 ms | 0.420 ms | tie | 0.93× |
| 1024 | 48 MiB | 12,288 | 1.694 ms | 1.269 ms | `dotpr` | 1.33× |
| 1024 | 96 MiB | 24,576 | 4.429 ms | 2.544 ms | `dotpr` | 1.74× |
| 1024 | 256 MiB | 65,536 | 11.824 ms | 6.891 ms | `dotpr` | 1.72× |
| 1536 | 1 MiB | 170 | 0.009 ms | 0.025 ms | `mmul` | 2.78× |
| 1536 | 4 MiB | 682 | 0.035 ms | 0.104 ms | `mmul` | 2.97× |
| 1536 | 16 MiB | 2,730 | 0.390 ms | 0.419 ms | tie | 0.93× |
| 1536 | 48 MiB | 8,192 | 1.689 ms | 1.262 ms | `dotpr` | 1.34× |
| 1536 | 96 MiB | 16,384 | 4.041 ms | 2.569 ms | `dotpr` | 1.57× |
| 1536 | 256 MiB | 43,690 | 10.467 ms | 6.808 ms | `dotpr` | 1.54× |

## vDSP_dotpr implementation for large vectors.

```swift
for slot in slots {
    // Skip slots that contain deleted vectors
    guard mapping.isLive(slot) else { continue }
    
    // Advance the matrix to where the slot is located, which is the slot index * the vector dimensions.
    let matrixBase = matrix.advanced(by: slot * dimensions)
    
    var score: Float = 0

    vDSP_dotpr(matrixBase, 1, queryBase, 1, &score, vDSP_Length(dimensions))
    
    // There is a chance that writing got corrupted and the score
    guard score.isFinite else {
        Log.logger.warning("Skipping slot \(slot) because it's score is NaN.")
        continue
    }
    
    // Insert the slot into the TopK stack. If the score breaks into the top `k` items it will be saved here, otherwise it will be trashed.
    resultStack.insert(id: slot, distance: score)
}
```
