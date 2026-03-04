//
//  ContentView.swift
//  ThroughMySpace
//
//  Created by admin on 2026/03/03.
//

// ContentView.swift
// ThroughMySpace
//
// アプリの起動画面。空間写真の選択UIを表示する。
//
// 【React Native との対比】
// この View = React Native の Screen コンポーネントに相当。
// @Environment = React の useContext() に相当。
// @State = React の useState() に相当。
// .task { } = React の useEffect(() => { ... }, [dep]) に相当。

import SwiftUI
import PhotosUI
import RealityKit
import UIKit

// ------------------------------------------------------------------
// PHPickerViewController ラッパー
//
// SwiftUI の PhotosPicker では visionOS で「確定ボタン」が必要だが、
// PHPickerConfiguration.selection = .continuous を使うと
// タップした瞬間に即選択完了になる。
//
// PHAsset.fetchAssets はフォトライブラリのフルアクセス権限が必要。
// 代わりに NSItemProvider からデータを直接取得する（権限不要）。
//
// UIViewControllerRepresentable = React Native の NativeModules のように
// UIKit のコンポーネントを SwiftUI から使うための橋渡し。
// ------------------------------------------------------------------
struct SpatialPhotoPicker: UIViewControllerRepresentable {
    // 選択完了時に呼ばれるコールバック（Data を直接渡す）
    var onSelect: (Data) -> Void
    // ピッカーを閉じるためのフラグ
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, isPresented: $isPresented)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        // PHPickerConfiguration() = フォトライブラリへのアクセス権限不要モード
        // PHPickerConfiguration(photoLibrary: .shared()) だとフルアクセスが必要になる
        var config = PHPickerConfiguration()

        // .continuous = タップした瞬間に選択を通知（確定ボタン不要）
        config.selection = .continuous
        config.selectionLimit = 1

        #if targetEnvironment(simulator)
        config.filter = .images
        #else
        config.filter = .spatialMedia  // 実機：空間写真のみ
        #endif

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    // PHPickerViewControllerDelegate を実装するクラス
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var onSelect: (Data) -> Void
        @Binding var isPresented: Bool

        init(onSelect: @escaping (Data) -> Void, isPresented: Binding<Bool>) {
            self.onSelect = onSelect
            self._isPresented = isPresented
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let result = results.first else {
                isPresented = false
                return
            }

            // NSItemProvider からデータを直接取得（フォトライブラリ権限不要）
            // kUTTypeImage ではなく "public.heic" や "public.image" を指定する
            let provider = result.itemProvider

            // 空間写真は HEIC なので "public.heic" を優先、
            // それがなければ汎用 "public.image" にフォールバック
            let typeIdentifier: String
            if provider.hasItemConformingToTypeIdentifier("public.heic") {
                typeIdentifier = "public.heic"
            } else {
                typeIdentifier = "public.image"
            }

            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] data, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isPresented = false
                    if let data {
                        self.onSelect(data)
                    } else {
                        print("⚠️ 写真データの取得失敗: \(error?.localizedDescription ?? "不明")")
                    }
                }
            }
        }
    }
}

struct ContentView: View {
    // AppModel を Environment から取得（グローバル状態）
    @Environment(AppModel.self) private var appModel

    // Immersive Space の開閉を操作するSwiftUI環境値
    @Environment(\.openImmersiveSpace) var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace

    // メインウィンドウを閉じるための環境値
    @Environment(\.dismissWindow) var dismissWindow

    // ピッカーの表示フラグ
    @State private var showPicker = false

    // エラーアラートの表示フラグ
    @State private var showErrorAlert = false

    var body: some View {
        VStack(spacing: 16) {
            // ヘッダー（アイコン＋タイトル）
            VStack(spacing: 10) {
                // アプリアイコン
                // Resources/images/ に置いたファイルは Assets.xcassets 外なので
                // Bundle.main から UIImage で読み込む
                if let uiImage = UIImage(named: "icon", in: .main, with: nil)
                    ?? UIImage(contentsOfFile: Bundle.main.path(forResource: "icon", ofType: "png") ?? "") {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                }

                Text("Through My Space")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("自分の空間で体験する視覚症状シミュレーター")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // 写真選びのヒント
            PhotoTipsView()

            // 空間写真の選択ボタン
            // タップすると SpatialPhotoPicker (PHPickerViewController) がシートで開く
            // selection = .continuous により写真タップで即確定（確定ボタン不要）
            Button {
                showPicker = true
            } label: {
                Label("フォトライブラリから選ぶ", systemImage: "photo.badge.plus")
                    .font(.title3)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(appModel.isLoadingPhoto)

            // シミュレーター用の注意書き
            #if targetEnvironment(simulator)
            Text("⚠️ シミュレーターでは通常写真を使用します（左右同一画像）")
                .font(.caption2)
                .foregroundStyle(.orange)
            #endif

            // ローディング中の表示
            if appModel.isLoadingPhoto {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("空間写真を読み込んでいます...")
                        .foregroundStyle(.secondary)
                }
            }

            // 免責事項
            Text("このアプリが提供する体験は近似的なシミュレーションです。\n実際の視覚症状は個人差があります。\n医療診断・治療の代替として使用しないでください。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        // SpatialPhotoPicker をシートとして表示
        .sheet(isPresented: $showPicker) {
            SpatialPhotoPicker(
                onSelect: { data in
                    Task {
                        await loadAndOpenImmersiveSpace(from: data)
                    }
                },
                isPresented: $showPicker
            )
        }
        .alert("エラー", isPresented: $showErrorAlert) {
            Button("OK") { }
        } message: {
            Text(appModel.photoLoadError ?? "不明なエラーが発生しました")
        }
    }

    // ------------------------------------------------------------------
    // Data から写真を読み込んで Immersive Space を開く
    //
    // PHAsset 経由はフォトライブラリのフルアクセス権限が必要なため、
    // NSItemProvider から取得した Data を直接使う（権限不要）。
    //
    // 流れ：
    // 1. Data → SpatialPhotoLoader で左右画像を取り出す
    // 2. TextureResource を生成
    // 3. AppModel に保存
    // 4. Immersive Space を開く
    // 5. メインウィンドウを閉じる
    // ------------------------------------------------------------------
    private func loadAndOpenImmersiveSpace(from data: Data) async {
        appModel.isLoadingPhoto = true
        appModel.photoLoadError = nil

        do {
            let loader = SpatialPhotoLoader()
            let stereoPair = try loader.loadStereoImages(from: data)

            // CGImage → TextureResource（GPUテクスチャ）
            let leftTexture = try await loader.makeTextureResource(
                from: stereoPair.left,
                name: "SpatialLeft"
            )
            let rightTexture = try await loader.makeTextureResource(
                from: stereoPair.right,
                name: "SpatialRight"
            )

            // AppModel に保存（ImmersiveView が監視している）
            appModel.selectedStereoTextures = StereoTextures(
                left: leftTexture,
                right: rightTexture
            )

            // Immersive Space を開く（まだ開いていなければ）
            // ※ textureVersion のインクリメントは openImmersiveSpace の後に行う。
            //   ImmersiveView が生成される前に onChange が発火しても
            //   domeEntity が nil でテクスチャが適用されないため。
            //   初回は makeContent クロージャ内で直接適用する。
            //   再オープン後の onChange トリガーは textureVersion で行う。
            if appModel.immersiveSpaceState == .closed {
                await openImmersiveSpace(id: appModel.immersiveSpaceID)
            }

            // ImmersiveSpace が開いた後にカウンターを上げる
            // （ImmersiveSpace が既に開いている場合の再テクスチャ適用に使う）
            appModel.textureVersion += 1

            // 写真が読み込まれたらメインウィンドウを閉じる
            // フローティングパネルの「写真を変更」ボタンで再度開ける
            dismissWindow(id: appModel.mainWindowID)

        } catch {
            print("⚠️ 写真読み込みエラー: \(error)")
            appModel.photoLoadError = error.localizedDescription
            showErrorAlert = true
        }

        appModel.isLoadingPhoto = false
    }
}

// ------------------------------------------------------------------
// 効果的な写真の選び方ヒント（2列グリッド表示）
// ------------------------------------------------------------------
struct PhotoTipsView: View {
    // 症状カードのデータ（icon, color, symptom, tip, isComingSoon）
    private let tips: [(icon: String, color: Color, symptom: String, tip: String, isComingSoon: Bool)] = [
        ("circle.dashed", .orange, "視野狭窄",      "部屋全体が広く写った写真。周辺に家具や窓がある構図が効果的。",     false),
        ("paintpalette",  .purple, "色覚異常",      "赤・緑・オレンジなど彩度の高い色が多い写真ほど違いが分かりやすい。", false),
        ("sun.max",       .yellow, "白内障",        "光源（窓・照明）が多い写真で効果的。",                         false),
        ("circle.dotted", .gray,   "網膜色素変性症", "周辺に重要な物が多い構図で体験の差が際立つ。",                   false),
        ("scope",         .red,    "中心暗点",      "中央に顔や文字など「見たいもの」がある写真がわかりやすい。",        true),
        ("bubble.left",   .teal,   "飛蚊症",        "空・白壁など均一で明るい背景の写真で影が見えやすい。",            true),
    ]

    // 縦1列レイアウト
    var body: some View {
        VStack(spacing: 10) {
            Label("より体験が伝わる写真を選ぶには", systemImage: "lightbulb")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(spacing: 6) {
                ForEach(tips, id: \.symptom) { tip in
                    TipCard(
                        icon: tip.icon,
                        color: tip.color,
                        symptom: tip.symptom,
                        tip: tip.tip,
                        isComingSoon: tip.isComingSoon
                    )
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// 症状カード（1行）
private struct TipCard: View {
    let icon: String
    let color: Color
    let symptom: String
    let tip: String
    var isComingSoon: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(isComingSoon ? color.opacity(0.45) : color)
                .font(.subheadline)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(symptom)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(isComingSoon ? .secondary : .primary)
                    if isComingSoon {
                        Text("追加予定")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(tip)
                    .font(.caption2)
                    .foregroundStyle(isComingSoon ? .tertiary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
