// EntryNoticeView.swift
// ThroughMySpace
//
// 体験開始時に空間内に表示する免責事項・注意テキスト。
// ImmersiveView の RealityView Attachment として使用する。
// 5 秒後に ImmersiveView 側から自動フェードアウトされる。

import SwiftUI

struct EntryNoticeView: View {
    var body: some View {
        VStack(spacing: 16) {
            // アイコン + タイトル
            HStack(spacing: 10) {
                Image(systemName: "eye")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("体験を始める前に")
                    .font(.headline)
            }

            Divider()

            // 免責事項
            VStack(alignment: .leading, spacing: 8) {
                Label("このアプリが提供する体験は近似的なシミュレーションです。",
                      systemImage: "info.circle")
                    .font(.subheadline)
                Label("実際の視覚症状は個人差があります。",
                      systemImage: "person.2")
                    .font(.subheadline)
                Label("医療診断・治療の代替として使用しないでください。",
                      systemImage: "cross.case")
                    .font(.subheadline)
            }
            .foregroundStyle(.primary)

            Divider()

            // フェードアウトのヒント
            Text("このメッセージはまもなく消えます")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        // glass background
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .frame(width: 480)
    }
}

#Preview {
    EntryNoticeView()
        .padding()
}
