// InfoView.swift
// ThroughMySpace
//
// 症状選択時に FloatingPanel の下に展開される説明カード。
// 症状の概要・日常生活への影響・免責事項を表示する。
//
// 【表示タイミング】
// FloatingPanelView で症状（visualField/colorBlind）が選ばれたとき、
// パネルの下部に .transition でアニメーション展開する。

import SwiftUI

struct InfoView: View {
    let conditionType: ConditionType

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // 症状名ヘッダー
            HStack(spacing: 10) {
                Image(systemName: conditionType.iconName)
                    .font(.title2)
                    .foregroundStyle(conditionType.color)
                Text(conditionType.title)
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            Divider()

            // 詳細説明文
            Text(conditionType.detailDescription)
                .font(.body)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // 免責事項（仕様書で必須とされているテキスト）
            Text("これは近似的な体験です。実際の見え方は個人差があります。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

#Preview {
    VStack(spacing: 16) {
        InfoView(conditionType: .visualField)
        InfoView(conditionType: .colorBlind)
    }
    .padding()
    .frame(width: 640)
}
