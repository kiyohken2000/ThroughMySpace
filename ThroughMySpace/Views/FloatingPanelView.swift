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
    // 症状説明（InfoView）の表示フラグ
    @Binding var showInfo: Bool
    // パネルの最小化フラグ（true = 最小化されてヘッダーのみ表示）
    @Binding var isMinimized: Bool

    // AppModel 全体（dismissImmersiveSpace に必要）
    @Environment(AppModel.self) private var appModel
    // イマーシブスペースを閉じる環境値
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    // メインウィンドウを開く環境値
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ヘッダー行（常に表示）
            HStack {
                Text("症状を選択")
                    .font(.title)
                    .fontWeight(.semibold)

                Spacer()

                // 症状説明ボタン（症状選択中のみ有効）
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showInfo.toggle()
                    }
                } label: {
                    Image(systemName: showInfo ? "info.circle.fill" : "info.circle")
                        .font(.title2)
                        .foregroundStyle(
                            conditionSetting.type != .none
                                ? conditionSetting.type.color
                                : .secondary
                        )
                }
                .buttonStyle(.plain)
                .disabled(conditionSetting.type == .none)

                // 最小化/展開ボタン
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isMinimized.toggle()
                    }
                } label: {
                    Image(systemName: isMinimized ? "chevron.down.circle" : "chevron.up.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                // ホームに戻るボタン
                Button {
                    Task {
                        await dismissImmersiveSpace()
                        openWindow(id: appModel.mainWindowID)
                        appModel.selectedStereoTextures = nil
                        appModel.conditionSetting = ConditionSetting()
                    }
                } label: {
                    Label("ホームに戻る", systemImage: "house")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }

            // 展開時のみ表示するコンテンツ
            if !isMinimized {
                VStack(alignment: .leading, spacing: 20) {
                    Divider()
                        .padding(.top, 8)

                    // 症状選択ボタン群
                    HStack(spacing: 16) {
                        ForEach(ConditionType.allCases) { conditionType in
                            ConditionButton(
                                conditionType: conditionType,
                                isSelected: conditionSetting.type == conditionType
                            ) {
                                // 別の症状に切り替えたとき強度を軽度（0.3）にリセット
                                if conditionSetting.type != conditionType {
                                    conditionSetting.intensity = ConditionIntensity(0.3)
                                }
                                conditionSetting.type = conditionType
                                // 症状なしに戻したらInfoViewも閉じる
                                if conditionType == .none {
                                    showInfo = false
                                }
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
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(32)
        .frame(width: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .animation(.easeInOut(duration: 0.2), value: conditionSetting.type)
        .animation(.easeInOut(duration: 0.2), value: isMinimized)
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
    FloatingPanelView(
        conditionSetting: .constant(ConditionSetting()),
        showInfo: .constant(false),
        isMinimized: .constant(false)
    )
    .padding()
}
