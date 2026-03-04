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
    case none           = "none"            // 症状なし（元の空間写真）
    case visualField    = "visualField"     // 視野狭窄（緑内障など）
    case colorBlind     = "colorBlind"      // 色覚異常

    var id: String { rawValue }

    // 表示名
    var title: String {
        switch self {
        case .none:        return "症状なし"
        case .visualField: return "視野狭窄"
        case .colorBlind:  return "色覚異常"
        }
    }

    // 短い説明文（パネルに表示）
    var shortDescription: String {
        switch self {
        case .none:
            return "元の空間写真をそのまま体験します"
        case .visualField:
            return "緑内障などで起こる周辺視野の欠損を体験します"
        case .colorBlind:
            return "色の見え方の違いを体験します"
        }
    }

    // 詳細説明文（InfoView に表示）
    var detailDescription: String {
        switch self {
        case .none:
            return ""
        case .visualField:
            return """
                目の内圧が上がり、視神経が\
                ゆっくりと失われていく病気です。

                視野は少しずつ狭くなるため、\
                本人が気づかないことが多く、\
                発見時にはすでに進行していることも。
                日本の患者数は約400万人。
                """
        case .colorBlind:
            return """
                特定の色を感じる錐体細胞が\
                機能しない・弱い状態です。

                赤・緑・茶・オレンジが\
                似た色に見えるタイプが最も多く、\
                日本では男性の約5%に見られます。
                """
        }
    }

    // SF Symbols アイコン名
    var iconName: String {
        switch self {
        case .none:        return "eye"
        case .visualField: return "circle.dashed"
        case .colorBlind:  return "paintpalette"
        }
    }

    // テーマカラー
    var color: Color {
        switch self {
        case .none:        return .blue
        case .visualField: return .orange
        case .colorBlind:  return .purple
        }
    }
}

// 症状の強度（0.0 〜 1.0）
// 0.0 = 症状なし、1.0 = 最大強度
struct ConditionIntensity: Equatable {
    var value: Float

    // スライダーのステップ感のある表現（段階的に設定できる）
    static let presets: [(label: String, value: Float)] = [
        ("軽度", 0.3),
        ("中度", 0.6),
        ("重度", 1.0),
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
        case .deuteranopia: return "2型色覚（緑弱）"
        case .protanopia:   return "1型色覚（赤弱）"
        case .tritanopia:   return "3型色覚（青弱）"
        }
    }
}
