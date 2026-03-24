//
//  ParakeetModel.swift
//  HexCLI
//
//  Known Parakeet Core ML bundles that Hex supports.
//

import Foundation

enum ParakeetModel: String, CaseIterable, Sendable {
    case englishV2 = "parakeet-tdt-0.6b-v2-coreml"
    case multilingualV3 = "parakeet-tdt-0.6b-v3-coreml"

    var identifier: String { rawValue }

    var isEnglishOnly: Bool {
        self == .englishV2
    }
}
