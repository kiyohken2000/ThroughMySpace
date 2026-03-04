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
                Text("notice.title", tableName: "Localizable")
                    .font(.headline)
            }

            Divider()

            // 免責事項
            VStack(alignment: .leading, spacing: 8) {
                Label(String(localized: "notice.line1"),
                      systemImage: "info.circle")
                    .font(.subheadline)
                Label(String(localized: "notice.line2"),
                      systemImage: "person.2")
                    .font(.subheadline)
                Label(String(localized: "notice.line3"),
                      systemImage: "cross.case")
                    .font(.subheadline)
            }
            .foregroundStyle(.primary)

            Divider()

            // フェードアウトのヒント
            Text("notice.fade", tableName: "Localizable")
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
