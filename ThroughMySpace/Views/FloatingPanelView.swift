// FloatingPanelView.swift
// ThroughMySpace
//
// Immersive Space 内に浮かぶ症状選択パネル。
// ユーザーの正面やや下（視線の自然な位置）に配置される。
//
// 【React Native との対比】
// visionOS の ornament/window に相当するが、
// ここでは RealityView の attachment として実装する。
// attachment = RealityKit シーン内に SwiftUI View を埋め込む仕組み。
//
// 【パネルの構成】
// ┌─────────────────────────────────┐
// │  症状を選択                      │
// │  ○ 症状なし  ● 視野狭窄  ○ 色覚異常 │
// │  強度: ━━━━━●━━━━  60%          │
// │  [色覚異常タイプ選択]（条件付き）   │
// └─────────────────────────────────┘

import SwiftUI

struct FloatingPanelView: View {
    // AppModel を Binding で受け取る（変更を AppModel に反映させる）
    @Binding var conditionSetting: ConditionSetting
    // AppModel 全体（dismissImmersiveSpace に必要）
    @Environment(AppModel.self) private var appModel
    // イマーシブスペースを閉じる環境値
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    // メインウィンドウを開く環境値
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // パネル本体 + 症状説明カードを縦に並べる
        VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 20) {

            // ヘッダー行（タイトル + ホームに戻るボタン）
            HStack {
                Text("症状を選択")
                    .font(.title)
                    .fontWeight(.semibold)

                Spacer()

                // ホームに戻るボタン：
                // イマーシブスペースを閉じてメインウィンドウを再表示する
                Button {
                    Task {
                        await dismissImmersiveSpace()
                        // イマーシブ解除後にメインウィンドウを開く
                        openWindow(id: appModel.mainWindowID)
                        // AppModel の状態をリセット（写真選択画面に戻る）
                        appModel.selectedStereoTextures = nil
                        appModel.conditionSetting = ConditionSetting()
                    }
                } label: {
                    Label("ホームに戻る", systemImage: "house")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }

            // 症状選択ボタン群
            HStack(spacing: 16) {
                ForEach(ConditionType.allCases) { conditionType in
                    ConditionButton(
                        conditionType: conditionType,
                        isSelected: conditionSetting.type == conditionType
                    ) {
                        conditionSetting.type = conditionType
                    }
                }
            }

            // 強度スライダー（「症状なし」以外のとき表示）
            if conditionSetting.type != .none {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("強度")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(conditionSetting.intensity.value * 100))%")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }

                    // Slider = React Native の Slider コンポーネントに相当
                    Slider(
                        value: Binding(
                            get: { Double(conditionSetting.intensity.value) },
                            set: { conditionSetting.intensity = ConditionIntensity(Float($0)) }
                        ),
                        in: 0.1...1.0,
                        step: 0.05
                    )
                    .tint(conditionSetting.type.color)

                    // 強度プリセットボタン（軽度/中度/重度）
                    HStack(spacing: 8) {
                        ForEach(ConditionIntensity.presets, id: \.label) { preset in
                            Button(preset.label) {
                                conditionSetting.intensity = ConditionIntensity(preset.value)
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                            .tint(
                                abs(conditionSetting.intensity.value - preset.value) < 0.01
                                    ? conditionSetting.type.color
                                    : .secondary
                            )
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // 色覚異常タイプ選択（色覚異常選択時のみ表示）
            if conditionSetting.type == .colorBlind {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("色覚タイプ")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Picker("色覚タイプ", selection: $conditionSetting.colorBlindType) {
                        ForEach(ColorBlindType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

        }
        .padding(32)
        .frame(width: 640)
        // visionOS のガラス素材（.regularMaterial）を背景に使う
        // React Native の `backgroundColor: 'rgba(0,0,0,0.5)'` より自然な見た目
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .animation(.easeInOut(duration: 0.2), value: conditionSetting.type)

        // 症状説明カード（症状なし以外のとき展開）
        if conditionSetting.type != .none {
            InfoView(conditionType: conditionSetting.type)
                .frame(width: 640)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }

        } // 外側VStack終わり
        .animation(.easeInOut(duration: 0.2), value: conditionSetting.type)
    }
}

// ------------------------------------------------------------------
// 個別の症状選択ボタン
// ------------------------------------------------------------------
private struct ConditionButton: View {
    let conditionType: ConditionType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                // アイコン
                Image(systemName: conditionType.iconName)
                    .font(.title)
                    .frame(height: 36)

                // ラベル
                Text(conditionType.title)
                    .font(.body)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .background(
                isSelected
                    ? conditionType.color.opacity(0.2)
                    : Color.clear
            )
            .foregroundStyle(isSelected ? conditionType.color : .secondary)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? conditionType.color : Color.clear,
                        lineWidth: 1.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    FloatingPanelView(conditionSetting: .constant(ConditionSetting()))
        .padding()
}
