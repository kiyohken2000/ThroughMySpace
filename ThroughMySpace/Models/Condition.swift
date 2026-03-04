// Condition.swift
// ThroughMySpace
//
// 視覚症状の種類と設定値を定義するモデル。
//
// 【React Native との対比】
// TypeScript の enum + type に相当する。
// Swift の enum はメソッドやプロパティを持てるのが特徴。

import SwiftUI

// 視覚症状の種類
enum ConditionType: String, CaseIterable, Identifiable {
    case none                 = "none"                 // 症状なし（元の空間写真）
    case visualField          = "visualField"          // 視野狭窄（緑内障など）
    case colorBlind           = "colorBlind"           // 色覚異常
    case cataract             = "cataract"             // 白内障（水晶体の混濁）
    case retinitispigmentosa  = "retinitispigmentosa"  // 網膜色素変性症（周辺から視野が失われる）
    case presbyopia           = "presbyopia"           // 老眼（近距離のピントが合わない）
    case astigmatism          = "astigmatism"          // 乱視（特定方向にブレる）

    var id: String { rawValue }

    // 表示名（ローカライズ対応）
    var title: String {
        switch self {
        case .none:                return String(localized: "condition.none.title")
        case .visualField:         return String(localized: "condition.visualField.title")
        case .colorBlind:          return String(localized: "condition.colorBlind.title")
        case .cataract:            return String(localized: "condition.cataract.title")
        case .retinitispigmentosa: return String(localized: "condition.rp.title")
        case .presbyopia:          return String(localized: "condition.presbyopia.title")
        case .astigmatism:         return String(localized: "condition.astigmatism.title")
        }
    }

    // 短い説明文（パネルに表示）
    var shortDescription: String {
        switch self {
        case .none:                return String(localized: "condition.none.short")
        case .visualField:         return String(localized: "condition.visualField.short")
        case .colorBlind:          return String(localized: "condition.colorBlind.short")
        case .cataract:            return String(localized: "condition.cataract.short")
        case .retinitispigmentosa: return String(localized: "condition.rp.short")
        case .presbyopia:          return String(localized: "condition.presbyopia.short")
        case .astigmatism:         return String(localized: "condition.astigmatism.short")
        }
    }

    // 詳細説明文（InfoView に表示）
    var detailDescription: String {
        switch self {
        case .none:                return ""
        case .visualField:         return String(localized: "condition.visualField.detail")
        case .colorBlind:          return String(localized: "condition.colorBlind.detail")
        case .cataract:            return String(localized: "condition.cataract.detail")
        case .retinitispigmentosa: return String(localized: "condition.rp.detail")
        case .presbyopia:          return String(localized: "condition.presbyopia.detail")
        case .astigmatism:         return String(localized: "condition.astigmatism.detail")
        }
    }

    // SF Symbols アイコン名
    var iconName: String {
        switch self {
        case .none:                return "eye"
        case .visualField:         return "circle.dashed"
        case .colorBlind:          return "paintpalette"
        case .cataract:            return "sun.max"
        case .retinitispigmentosa: return "circle.dotted"
        case .presbyopia:          return "eyeglasses"
        case .astigmatism:         return "lines.measurement.horizontal"
        }
    }

    // テーマカラー
    var color: Color {
        switch self {
        case .none:                return .blue
        case .visualField:         return .orange
        case .colorBlind:          return .purple
        case .cataract:            return .yellow
        case .retinitispigmentosa: return .gray
        case .presbyopia:          return .green
        case .astigmatism:         return .cyan
        }
    }
}

// 症状の強度（0.0 〜 1.0）
// 0.0 = 症状なし、1.0 = 最大強度
struct ConditionIntensity: Equatable {
    var value: Float

    // スライダーのステップ感のある表現（段階的に設定できる）
    // ローカライズは使用側（FloatingPanelView）で String(localized:) を呼ぶ
    static let presets: [(labelKey: String, value: Float)] = [
        ("intensity.mild",     0.3),
        ("intensity.moderate", 0.6),
        ("intensity.severe",   1.0),
    ]

    init(_ value: Float) {
        self.value = max(0, min(1, value))  // 0〜1にクランプ
    }
}

// 現在選択中の症状設定
struct ConditionSetting: Equatable {
    var type: ConditionType = .none
    var intensity: ConditionIntensity = ConditionIntensity(0.0)  // 症状選択直後は変化なしから開始

    // 色覚異常のサブタイプ
    var colorBlindType: ColorBlindType = .deuteranopia
}

// 色覚異常のタイプ（Brettel 1997 に基づく分類）
enum ColorBlindType: String, CaseIterable, Identifiable {
    case deuteranopia  = "deuteranopia"   // 2型色覚（緑弱）最も多い
    case protanopia    = "protanopia"     // 1型色覚（赤弱）
    case tritanopia    = "tritanopia"     // 3型色覚（青弱）稀

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deuteranopia: return String(localized: "colorBlind.deuteranopia")
        case .protanopia:   return String(localized: "colorBlind.protanopia")
        case .tritanopia:   return String(localized: "colorBlind.tritanopia")
        }
    }
}
