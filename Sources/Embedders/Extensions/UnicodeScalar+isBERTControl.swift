//
//  Scalar+isBERTControl.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/24/26.
//


extension Unicode.Scalar {
    var isBERTControlCharacter: Bool {
        if self == "\t" || self == "\n" || self == "\r" {
            return false
        }
        
        let controlCategories: [Unicode.GeneralCategory] = [.control, .format, .privateUse, .surrogate, .unassigned]
        
        return controlCategories.contains(self.properties.generalCategory)
    }
}
