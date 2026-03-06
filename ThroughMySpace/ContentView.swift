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

        // .continuous はタップ即通知だが、visionOS の spatialMedia フィルタとの組み合わせで
        // データ未準備のまま didFinishPicking が呼ばれクラッシュする事例があるため使わない。
        // デフォルト（.default）を使い、確定ボタンで安全に確定させる。
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
        // 二重呼び出し防止フラグ（didFinishPicking が複数回来ても1回だけ処理する）
        private var hasSelected = false

        init(onSelect: @escaping (Data) -> Void, isPresented: Binding<Bool>) {
            self.onSelect = onSelect
            self._isPresented = isPresented
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // すでに処理済みなら何もしない
            guard !hasSelected else { return }

            guard let result = results.first else {
                isPresented = false
                return
            }

            hasSelected = true

            // NSItemProvider からデータを直接取得（フォトライブラリ権限不要）
            let provider = result.itemProvider

            // 空間写真は HEIC なので "public.heic" を優先、
            // それがなければ汎用 "public.image" にフォールバック
            let typeIdentifier: String
            if provider.hasItemConformingToTypeIdentifier("public.heic") {
                typeIdentifier = "public.heic"
            } else {
                typeIdentifier = "public.image"
            }

            // ピッカーを先に閉じてから非同期でデータ取得する
            // データ取得完了を待ってから閉じると UI がフリーズして見えるため
            isPresented = false

            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] data, error in
                DispatchQueue.main.async {
                    guard let self else { return }
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

                Text("app.subtitle", tableName: "Localizable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // 写真選びのヒント
            PhotoTipsView()

            // 空間写真の必要条件の注意書き
            PhotoRequirementView()

            // 空間写真の選択ボタン
            // タップすると SpatialPhotoPicker (PHPickerViewController) がシートで開く
            // selection = .continuous により写真タップで即確定（確定ボタン不要）
            Button {
                showPicker = true
            } label: {
                Label(String(localized: "button.selectPhoto"), systemImage: "photo.badge.plus")
                    .font(.title3)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(appModel.isLoadingPhoto)

            // シミュレーター用の注意書き
            #if targetEnvironment(simulator)
            Text("simulator.warning", tableName: "Localizable")
                .font(.caption2)
                .foregroundStyle(.orange)
            #endif

            // ローディング中の表示
            if appModel.isLoadingPhoto {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("loading.photo", tableName: "Localizable")
                        .foregroundStyle(.secondary)
                }
            }

            // 免責事項
            Text("disclaimer.short", tableName: "Localizable")
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
        .alert(String(localized: "alert.error.title"), isPresented: $showErrorAlert) {
            Button("OK") { }
        } message: {
            Text(appModel.photoLoadError ?? String(localized: "alert.error.unknown"))
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

            // 【重要】CGImageSourceCreateWithData などの重い画像パース処理を
            // バックグラウンドスレッドで実行する。
            // メインスレッドで大きな空間写真（数十MB）を同期処理すると
            // ウォッチドッグタイムアウトでクラッシュすることがある。
            // loader は nonisolated メソッドを持つため、detached から安全に呼べる。
            let stereoPair = try await Task.detached(priority: .userInitiated) {
                return try loader.loadStereoImages(from: data)
            }.value

            // CGImage → TextureResource（GPUテクスチャ）
            // 左右を順番に生成し、CGImage の参照を早期に手放してメモリを節約する。
            // 同時生成するとピーク時のメモリ使用量が倍になり OOM kill されることがある。
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
    // 症状カードのデータ（icon, color, symptomKey, tipKey, isComingSoon）
    // symptomKey / tipKey は Localizable.strings のキー
    private let tips: [(icon: String, color: Color, symptomKey: String, tipKey: String, isComingSoon: Bool)] = [
        ("circle.dashed",              .orange, "condition.visualField.title",   "tip.visualField.text",   false),
        ("paintpalette",               .purple, "condition.colorBlind.title",    "tip.colorBlind.text",    false),
        ("sun.max",                    .yellow, "condition.cataract.title",      "tip.cataract.text",      false),
        ("circle.dotted",              .gray,   "condition.rp.title",            "tip.rp.text",            false),
        ("eyeglasses",                 .green,  "condition.presbyopia.title",    "tip.presbyopia.text",    false),
        ("lines.measurement.horizontal", .cyan, "condition.astigmatism.title",   "tip.astigmatism.text",   false),
        ("scope",                      .red,    "tip.scotoma.label",             "tip.scotoma.text",       false),
        ("bubble.left",                .teal,   "tip.floaters.label",            "tip.floaters.text",      false),
    ]

    // 縦1列レイアウト
    var body: some View {
        VStack(spacing: 10) {
            Label(String(localized: "tipsView.header"), systemImage: "lightbulb")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(spacing: 6) {
                ForEach(tips, id: \.symptomKey) { tip in
                    TipCard(
                        icon: tip.icon,
                        color: tip.color,
                        symptom: String(localized: String.LocalizationValue(tip.symptomKey)),
                        tip: String(localized: String.LocalizationValue(tip.tipKey)),
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
                        Text("badge.comingSoon", tableName: "Localizable")
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

// ------------------------------------------------------------------
// 空間写真の必要条件を示す注意書き
// ボタンを押す前にユーザーが空間写真を持っているか確認できるよう表示する
// ------------------------------------------------------------------
struct PhotoRequirementView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "camera.aperture")
                .foregroundStyle(.blue)
                .font(.subheadline)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("photo.requirement.title", tableName: "Localizable")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("photo.requirement.body", tableName: "Localizable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.blue.opacity(0.25), lineWidth: 1)
        )
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
