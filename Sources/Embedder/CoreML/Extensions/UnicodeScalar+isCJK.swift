//
//  UnicodeScalar+isCJK.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/23/26.
//

extension Unicode.Scalar {
    /// Checks whether a character is in the CJK unicode blocks
    /// - A character is in this block if it is in this list: https://en.wikipedia.org/wiki/CJK_Unified_Ideographs_(Unicode_block)
    ///
    /// Implementation adapted from original rust code: https://github.com/huggingface/tokenizers/blob/b62132e4e0ec7518caba201408a680819dfdcd22/tokenizers/src/normalizers/bert.rs#L36
    var isCJKUnifiedIdeograph: Bool {
        switch self.value {
        case 0x4E00...0x9FFF: return true
        case 0x3400...0x4DBF: return true
        case 0x20000...0x2A6DF: return true
        case 0x2A700...0x2B73F: return true
        case 0x2B740...0x2B81F: return true
        case 0x2B920...0x2CEAF: return true
        case 0xF900...0xFAFF: return true
        case 0x2F800...0x2FA1F: return true
        default: return false
        }
    }
}
