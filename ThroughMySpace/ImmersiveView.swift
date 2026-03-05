// ImmersiveView.swift
// ThroughMySpace
//
// Full Immersion Space の本体。
// 前方ドームメッシュに空間写真を表示し、
// 症状選択パネルを空間内に浮かべる。
//
// 【visionOS のマテリアル制約について】
// visionOS では CustomMaterial（Metal シェーダー直書き）が使用不可。
// ShaderGraph（USDA/Reality Composer Pro）は .reality コンパイルの問題あり。
//
// 【採用した方針：CPU フィルタリング + UnlitMaterial】
// Core Image を使って視野狭窄・色覚異常フィルターを Swift 側で適用し、
// 処理済みの画像を TextureResource として UnlitMaterial に渡す。
//
// 【パフォーマンス設計】
// ・写真の CGImage 抽出（重い処理）は初回のみ → @State に保存
// ・症状変更時はその CGImage にフィルターをかけるだけ（軽い処理）
// これにより強度スライダーの変更がスムーズに反映される。

import SwiftUI
import RealityKit
import RealityKitContent
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import ARKit

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace

    private let panelAttachmentID = "floatingPanel"
    private let noticeAttachmentID = "entryNotice"
    private let infoAttachmentID   = "infoPanel"

    // ドームEntityへの参照を保持
    @State private var domeEntity: ModelEntity? = nil

    // 体験開始時の注意テキスト表示フラグ
    // true = 表示中、false = フェードアウト済み
    @State private var showEntryNotice = true

    // 症状説明（InfoView）の表示フラグ
    // FloatingPanel の ⓘ ボタンで切り替える
    @State private var showInfo = false

    // フローティングパネルの最小化フラグ
    // true = ヘッダーのみ表示
    @State private var isPanelMinimized = false

    // 写真の CGImage を保存（MTLTexture → CGImage の変換は一度だけ行う）
    // nil = まだ抽出していない
    @State private var sourceCGImage: CGImage? = nil

    // Core Image のコンテキスト（再生成を避けるために保持）
    @State private var ciContext = CIContext()

    // 現在処理中のフィルタータスク（連打時に前のタスクをキャンセルするため）
    @State private var filterTask: Task<Void, Never>? = nil

    // ------------------------------------------------------------------
    // ARKit セッション（アイトラッキング用）
    //
    // WorldTrackingProvider でヘッドの向きを毎フレーム取得する。
    // visionOS の Full Immersive Space では追加権限なしで利用できる。
    //
    // 【React Native との対比】
    // iOS の ARSession に相当するが、visionOS では ARKitSession を使う。
    // ------------------------------------------------------------------
    @State private var arkitSession   = ARKitSession()
    @State private var worldTracking  = WorldTrackingProvider()

    var body: some View {
        RealityView { content, attachments in
            // MARK: 背景球体
            content.add(makeBackgroundSphere())

            // MARK: ドームメッシュ
            let dome = makeDomeEntity()
            dome.name = "StereoDome"
            content.add(dome)
            domeEntity = dome

            // 初回のテクスチャ適用
            await applyMaterial(to: dome,
                                textures: appModel.selectedStereoTextures,
                                setting: appModel.conditionSetting)

            // MARK: フローティングパネルを 3D 空間に配置
            // 少し上（y=0.6）・正面方向（z=-1.2）に浮かせる
            if let panelEntity = attachments.entity(for: panelAttachmentID) {
                panelEntity.position = SIMD3<Float>(0, 0.6, -1.2)
                content.add(panelEntity)

                // MARK: 症状説明（InfoView）をパネルの子として配置
                // 親（パネル）の座標系でパネルのすぐ上（y=0.35）に配置
                // 親が移動しても一緒に動く
                if let infoEntity = attachments.entity(for: infoAttachmentID) {
                    infoEntity.position = SIMD3<Float>(0, 0.35, 0)
                    panelEntity.addChild(infoEntity)
                }

                // MARK: 体験開始時の注意テキストもパネルの子として配置
                // InfoView と同じ位置（同時に表示されることはない）
                if let noticeEntity = attachments.entity(for: noticeAttachmentID) {
                    noticeEntity.position = SIMD3<Float>(0, 0.35, 0)
                    panelEntity.addChild(noticeEntity)
                }
            }

        } attachments: {
            Attachment(id: panelAttachmentID) {
                @Bindable var model = appModel
                FloatingPanelView(
                    conditionSetting: $model.conditionSetting,
                    showInfo: $showInfo,
                    isMinimized: $isPanelMinimized
                )
            }

            // 症状説明カード（showInfo = true のとき表示）
            // FloatingPanel の ⓘ ボタンで切り替える
            Attachment(id: infoAttachmentID) {
                if showInfo {
                    InfoView(conditionType: appModel.conditionSetting.type)
                        .frame(width: 640)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            // 体験開始時の免責事項・注意テキスト
            // showEntryNotice が false になるとフェードアウト
            Attachment(id: noticeAttachmentID) {
                if showEntryNotice {
                    EntryNoticeView()
                        .transition(.opacity)
                }
            }
        }
        // 体験開始時の注意テキストを 5 秒後に自動フェードアウト
        .task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation(.easeOut(duration: 1.0)) {
                showEntryNotice = false
            }
        }
        // ARKit セッション開始（アイトラッキング用）
        // WorldTrackingProvider でヘッドの向きを毎フレーム取得する
        .task {
            await startARKitTracking()
        }
        // 視線位置が更新されたとき：中心暗点・飛蚊症フィルターを再適用
        // 他の症状では視線追跡が不要なので、条件を絞ってパフォーマンスを守る
        .onChange(of: appModel.gazeNormalized) { _, _ in
            let type = appModel.conditionSetting.type
            guard type == .scotoma || type == .floaters else { return }
            guard let dome = domeEntity else { return }
            filterTask?.cancel()
            filterTask = Task { @MainActor in
                await applyMaterial(to: dome,
                                    textures: appModel.selectedStereoTextures,
                                    setting: appModel.conditionSetting)
            }
        }
        // 写真が変わったとき：CGImageキャッシュをクリアして再抽出
        .onChange(of: appModel.textureVersion) { _, _ in
            sourceCGImage = nil  // キャッシュをクリア
            guard let dome = domeEntity else { return }
            filterTask?.cancel()
            filterTask = Task { @MainActor in
                await applyMaterial(to: dome,
                                    textures: appModel.selectedStereoTextures,
                                    setting: appModel.conditionSetting)
            }
        }
        // 症状設定が変わったとき：保存済み CGImage にフィルターをかけ直す
        .onChange(of: appModel.conditionSetting) { _, newSetting in
            guard let dome = domeEntity else { return }
            // 前のタスクをキャンセル（スライダー連打対策）
            filterTask?.cancel()
            filterTask = Task { @MainActor in
                await applyMaterial(to: dome,
                                    textures: appModel.selectedStereoTextures,
                                    setting: newSetting)
            }
            // 症状なしに切り替えたら InfoView を閉じる
            if newSetting.type == .none {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showInfo = false
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // ドームエンティティを生成する
    // ------------------------------------------------------------------
    @MainActor
    private func makeDomeEntity() -> ModelEntity {
        do {
            let mesh = try DomeMesh.generate(
                radius: 3.0,
                hFovDeg: 120.0,
                vFovDeg: 90.0,
                hSegments: 60,
                vSegments: 45
            )
            let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .black)])
            entity.position = SIMD3<Float>(0, 0, 0)
            return entity
        } catch {
            print("⚠️ ドームメッシュの生成失敗: \(error)")
            return ModelEntity()
        }
    }

    // ------------------------------------------------------------------
    // 背景球体（ドーム外を暗く覆う）
    // ------------------------------------------------------------------
    @MainActor
    private func makeBackgroundSphere() -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: 4.0)
        var material = UnlitMaterial(color: .init(white: 0.02, alpha: 1.0))
        material.faceCulling = .none
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "BackgroundSphere"
        return entity
    }

    // ------------------------------------------------------------------
    // テクスチャと症状設定をドームに適用する
    //
    // 【処理の流れ】
    // 1. sourceCGImage がなければ TextureResource から抽出して保存
    // 2. 症状が「なし」なら元テクスチャをそのまま使う
    // 3. 症状あり → CGImage にフィルターをかけて TextureResource を生成
    // 4. UnlitMaterial に設定してドームに適用
    // ------------------------------------------------------------------
    @MainActor
    private func applyMaterial(
        to entity: ModelEntity,
        textures: StereoTextures?,
        setting: ConditionSetting
    ) async {
        guard let textures else {
            entity.model?.materials = [UnlitMaterial(color: .black)]
            return
        }

        // CGImage がキャッシュされていなければ抽出する
        // この処理は一度だけ（写真切り替え時にクリアされるまで）
        if sourceCGImage == nil {
            sourceCGImage = await extractCGImage(from: textures.left)
            if sourceCGImage == nil {
                print("⚠️ CGImage 抽出失敗、元テクスチャを使用")
                applyUnlit(texture: textures.left, to: entity)
                return
            }
            print("✅ CGImage キャッシュ完了: \(sourceCGImage!.width)x\(sourceCGImage!.height)")
        }

        guard let cgImage = sourceCGImage else { return }

        // タスクキャンセルチェック（スライダー連打でキャンセルされた場合は何もしない）
        if Task.isCancelled { return }

        // 症状なし → 元テクスチャをそのまま適用（フィルター不要）
        if setting.type == .none {
            applyUnlit(texture: textures.left, to: entity)
            print("✅ マテリアル更新: 症状なし")
            return
        }

        // フィルターを適用した CIImage を生成
        let ciImage = CIImage(cgImage: cgImage)
        let filteredCI: CIImage

        switch setting.type {
        case .none:
            // ここには来ない（上でreturnしている）
            filteredCI = ciImage

        case .visualField:
            filteredCI = applyVignetteFilter(to: ciImage, intensity: setting.intensity.value)

        case .colorBlind:
            filteredCI = applyColorBlindFilter(
                to: ciImage,
                type: setting.colorBlindType,
                intensity: setting.intensity.value
            )

        case .cataract:
            filteredCI = applyCataractFilter(to: ciImage, intensity: setting.intensity.value)

        case .retinitispigmentosa:
            filteredCI = applyRetinitisFilter(to: ciImage, intensity: setting.intensity.value)

        case .presbyopia:
            filteredCI = applyPresbyopiaFilter(to: ciImage, intensity: setting.intensity.value)

        case .astigmatism:
            filteredCI = applyAstigmatismFilter(to: ciImage, intensity: setting.intensity.value)

        case .scotoma:
            filteredCI = applyScotomaFilter(
                to: ciImage,
                intensity: setting.intensity.value,
                center: appModel.gazeNormalized
            )

        case .floaters:
            filteredCI = applyFloatersFilter(
                to: ciImage,
                intensity: setting.intensity.value,
                center: appModel.gazeNormalized,
                floatersType: setting.floatersType
            )
        }

        // キャンセルチェック（重い処理の後）
        if Task.isCancelled { return }

        // CIImage → CGImage → TextureResource
        let extent = filteredCI.extent
        guard let outputCGImage = ciContext.createCGImage(filteredCI, from: extent) else {
            print("⚠️ CIContext.createCGImage 失敗、元テクスチャを使用")
            applyUnlit(texture: textures.left, to: entity)
            return
        }

        do {
            let filteredTexture = try await TextureResource(
                image: outputCGImage,
                withName: nil,
                options: .init(semantic: .color)
            )
            applyUnlit(texture: filteredTexture, to: entity)
            print("✅ マテリアル更新: mode=\(setting.type.rawValue), intensity=\(setting.intensity.value)")
        } catch {
            print("⚠️ TextureResource 生成失敗: \(error)")
            applyUnlit(texture: textures.left, to: entity)
        }
    }

    // ------------------------------------------------------------------
    // UnlitMaterial にテクスチャを設定してエンティティに適用するヘルパー
    // ------------------------------------------------------------------
    @MainActor
    private func applyUnlit(texture: TextureResource, to entity: ModelEntity) {
        var material = UnlitMaterial()
        material.color = .init(texture: .init(texture))
        material.faceCulling = .none
        entity.model?.materials = [material]
    }

    // ------------------------------------------------------------------
    // TextureResource から CGImage を抽出する
    //
    // 処理コスト：高（GPU → CPU メモリコピー）
    // そのため一度だけ実行して @State に保存する。
    // ------------------------------------------------------------------
    @MainActor
    private func extractCGImage(from texture: TextureResource) async -> CGImage? {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("⚠️ Metal デバイス取得失敗")
            return nil
        }

        let width  = texture.width
        let height = texture.height

        // テクスチャのピクセルデータを受け取るための MTLTexture を作成
        //
        // 【重要】rgba8Unorm_srgb を使う理由：
        // 空間写真は sRGB 画像。TextureResource.copy(to:) でコピーするとき、
        // rgba8Unorm（リニア）にすると GPU がガンマを除去したリニア値を書き込む。
        // そのデータを CGContext（DeviceRGB = sRGB）に渡すと「暗い画像」になる。
        // rgba8Unorm_srgb にすることで sRGB エンコード済みの値がそのまま保持される。
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        // shaderWrite: copy(to:) が書き込めるように必要
        // shared: CPU から読み取れるように必要
        descriptor.usage       = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared

        guard let mtlTexture = device.makeTexture(descriptor: descriptor) else {
            print("⚠️ MTLTexture 作成失敗")
            return nil
        }

        // TextureResource → MTLTexture へコピー
        do {
            try await texture.copy(to: mtlTexture)
        } catch {
            print("⚠️ texture.copy 失敗: \(error)")
            return nil
        }

        // MTLTexture → ピクセルバッファ → CGImage
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        mtlTexture.getBytes(
            &pixels,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            // MTLTexture からコピーしたデータは非プリマルチプライ（straight alpha）
            // premultipliedLast にするとアルファが1.0未満のとき RGB が暗くなる
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            print("⚠️ CGContext 作成失敗")
            return nil
        }

        return context.makeImage()
    }

    // ------------------------------------------------------------------
    // 視野狭窄フィルター（円形ビネット効果）
    //
    // 【緑内障などの視野狭窄の特徴】
    // ・視野の外周（周辺部）が見えなくなる
    // ・中心視野は保たれる（末期まで）
    // ・境界はなだらかなグラデーション
    //
    // 【実装】
    // CIVignetteEffect を使う。CIVignette より細かく制御できる。
    //   center: 暗くならない中心点（画像の中心 = 正面）
    //   radius: 明るい中心の半径（大きいほど視野が広い）
    //   intensity: 暗さ（大きいほど周辺が暗い）
    //   falloff: 境界のなだらかさ（大きいほどぼんやり）
    //
    // 【intensity=0.0 の設計】
    //   radius を画像全体より大きくし、intensity も低くすることで
    //   ほぼ元画像と変わらない見た目にする
    // ------------------------------------------------------------------
    private func applyVignetteFilter(to image: CIImage, intensity: Float) -> CIImage {
        // intensity が非常に小さい場合はフィルターをかけない（元画像そのまま）
        // CIVignetteEffect は intensity=0 でも完全にゼロにはならないため
        guard intensity > 0.01 else { return image }

        let width  = image.extent.width
        let height = image.extent.height

        // 画像の中心を視野の中心として設定
        let center = CGPoint(x: width / 2, y: height / 2)

        // 「明るい中心の半径」を intensity に応じて変える
        // intensity=0.0（最小）: 短辺の 80%（周辺がわずかに暗くなる程度）
        // intensity=1.0（最大）: 短辺の 8%（重度の視野狭窄）
        let baseRadius = Float(min(width, height))
        let radius = baseRadius * mix(0.8, 0.08, t: intensity)

        let filter = CIFilter.vignetteEffect()
        filter.inputImage  = image
        filter.center      = center
        filter.radius      = radius
        filter.intensity   = mix(0.8, 2.0, t: intensity)
        filter.falloff     = mix(0.8, 0.1, t: intensity)  // 重いほど境界がシャープ

        return filter.outputImage ?? image
    }

    // ------------------------------------------------------------------
    // 色覚異常フィルター（CIColorMatrix + 彩度調整）
    //
    // 【RGB変換行列について】
    // CIColorMatrix は [R, G, B, A] → [R', G', B', A'] の線形変換。
    // rVector = 出力 R' を計算するときの [入力R, G, B, A] の係数。
    //
    // intensity=0.0 → 変換なし（元画像のまま）
    // intensity=1.0 → 完全変換
    //
    // 【2段階のフィルター】
    // 1. CIColorMatrix: 色チャンネルを混合して色混同を再現
    // 2. CIColorControls: 彩度を下げる（色覚異常では色の鮮やかさも低下する）
    // ------------------------------------------------------------------
    private func applyColorBlindFilter(
        to image: CIImage,
        type: ColorBlindType,
        intensity: Float
    ) -> CIImage {

        // intensity が非常に小さい場合はフィルターをかけない
        guard intensity > 0.01 else { return image }

        // 各タイプの完全変換行列（intensity=1.0 時に適用される値）
        //
        // 【行列の読み方】
        // rVec = (a, b, c, 0) は「出力R = 入力R*a + 入力G*b + 入力B*c」
        //
        // deuteranopia（緑弱）: 緑チャンネルが欠損→赤と緑が同じ黄色っぽい色に見える
        // protanopia（赤弱）:   赤チャンネルが欠損→赤が暗い黄緑〜灰色に見える
        // tritanopia（青弱）:   青チャンネルが欠損→青が緑に、黄色が赤に見える
        let (rVec, gVec, bVec): (CIVector, CIVector, CIVector)

        switch type {
        case .deuteranopia:
            // 2型色覚（緑弱）
            // 緑の情報が失われ、赤と緑が区別できなくなる
            // 特徴：緑→黄色っぽく、赤→茶色っぽく見える
            rVec = CIVector(x: 0.625, y: 0.375, z: 0.0, w: 0.0)
            gVec = CIVector(x: 0.700, y: 0.300, z: 0.0, w: 0.0)
            bVec = CIVector(x: 0.000, y: 0.300, z: 0.700, w: 0.0)

        case .protanopia:
            // 1型色覚（赤弱）
            // 赤の情報が失われ、赤が暗く見える
            // 特徴：赤→暗い緑〜灰色、緑→黄色っぽく見える
            rVec = CIVector(x: 0.567, y: 0.433, z: 0.0, w: 0.0)
            gVec = CIVector(x: 0.558, y: 0.442, z: 0.0, w: 0.0)
            bVec = CIVector(x: 0.000, y: 0.242, z: 0.758, w: 0.0)

        case .tritanopia:
            // 3型色覚（青弱）
            // 青の情報が失われ、青と緑・黄と赤が区別しにくくなる
            // 特徴：青→緑っぽく、黄色→ピンクっぽく見える
            rVec = CIVector(x: 0.950, y: 0.050, z: 0.0, w: 0.0)
            gVec = CIVector(x: 0.000, y: 0.433, z: 0.567, w: 0.0)
            bVec = CIVector(x: 0.000, y: 0.475, z: 0.525, w: 0.0)
        }

        // intensity で単位行列と変換行列を補間
        // 変化を分かりやすくするため二乗カーブ（低強度でも効果が出やすい）
        let tLinear = CGFloat(intensity)
        let t = tLinear * tLinear  // 二乗カーブ：低強度でも色変化が見えやすくなる
        func lerp(_ identity: CIVector, _ target: CIVector) -> CIVector {
            CIVector(
                x: identity.x * (1 - t) + target.x * t,
                y: identity.y * (1 - t) + target.y * t,
                z: identity.z * (1 - t) + target.z * t,
                w: identity.w * (1 - t) + target.w * t
            )
        }

        // Step 1: 色チャンネル混合（色混同の再現）
        let matrixFilter = CIFilter.colorMatrix()
        matrixFilter.inputImage = image
        matrixFilter.rVector    = lerp(CIVector(x: 1, y: 0, z: 0, w: 0), rVec)
        matrixFilter.gVector    = lerp(CIVector(x: 0, y: 1, z: 0, w: 0), gVec)
        matrixFilter.bVector    = lerp(CIVector(x: 0, y: 0, z: 1, w: 0), bVec)
        matrixFilter.aVector    = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrixFilter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)

        guard let matrixOutput = matrixFilter.outputImage else { return image }

        // Step 2: 彩度を下げる（色覚異常では色の鮮やかさも低下する）
        // saturation: 1.0 = 変化なし、0.0 = 完全グレースケール
        // intensity=1.0 で彩度 0.55 まで下げる（完全グレーにはしない）
        let saturation = mix(1.0, 0.55, t: intensity)
        let controlsFilter = CIFilter.colorControls()
        controlsFilter.inputImage  = matrixOutput
        controlsFilter.saturation  = saturation
        controlsFilter.brightness  = 0
        controlsFilter.contrast    = 1

        return controlsFilter.outputImage ?? matrixOutput
    }

    // ------------------------------------------------------------------
    // 白内障フィルター（Bloom 効果によるハレーション）
    //
    // 【白内障の視覚的特徴】
    // ・水晶体の混濁により光が散乱する
    // ・コントラストが下がり、全体がかすんで見える
    // ・光源周辺に光の輪（ハロー）が広がる
    // ・黄みがかった白濁（古い水晶体は黄色くなる）
    //
    // 【実装：3段階のパイプライン】
    // 1. CIColorControls: 彩度を下げ、コントラストを落とす（霞み）
    // 2. CIGaussianBlur: 全体をぼかす（光散乱）
    // 3. CIBlendWithMask: 元画像にぼかし画像を加算合成（Bloom）
    //    → 明るい部分だけがにじんで広がる効果
    // 4. CIColorMatrix: わずかに黄みを加える（水晶体の黄変）
    // ------------------------------------------------------------------
    private func applyCataractFilter(to image: CIImage, intensity: Float) -> CIImage {
        guard intensity > 0.01 else { return image }

        let width  = image.extent.width
        let height = image.extent.height

        // Step 1: 彩度低下・コントラスト低下・輝度上昇（霞み表現）
        // saturation: 1.0 → 彩度を落とす（白濁で色が薄れる）
        // contrast:   1.0 → 下げる（明暗差が減る）
        // brightness: 0.0 → 上げる（全体が白っぽくなる）
        let hazeFilter = CIFilter.colorControls()
        hazeFilter.inputImage  = image
        hazeFilter.saturation  = mix(1.0, 0.6, t: intensity)
        hazeFilter.contrast    = mix(1.0, 0.75, t: intensity)
        hazeFilter.brightness  = mix(0.0, 0.12, t: intensity)
        guard let hazedImage = hazeFilter.outputImage else { return image }

        // Step 2: ガウスぼかし（光散乱の表現）
        // radius: intensity=1.0 で短辺の 2.5%（全体がふんわりぼける）
        let blurRadius = Double(mix(0.0, Float(min(width, height)) * 0.025, t: intensity))
        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = hazedImage
        blurFilter.radius     = Float(blurRadius)
        guard let blurredImage = blurFilter.outputImage else { return hazedImage }

        // ぼかしで広がったはみ出し部分を元のサイズにクロップ
        let clampedBlur = blurredImage.cropped(to: image.extent)

        // Step 3: 輝度マスクを使った Bloom 加算合成
        // 明るい部分だけを抽出してぼかし画像を重ねる
        // → 光源周辺だけが「にじむ」Bloom 効果
        //
        // CIBlendWithMask:
        //   backgroundImage = 霞み処理した元画像
        //   inputImage      = ぼかした画像（Bloom 光）
        //   maskImage       = 輝度マスク（明るいほど白 = ぼかし画像が見える）
        let luminanceMask = hazedImage
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,   // グレースケール化
                kCIInputContrastKey: 2.0,      // コントラスト強調（明暗を二極化）
                kCIInputBrightnessKey: -0.1    // 暗い部分をさらに暗くする
            ])

        let bloomFilter = CIFilter(name: "CIBlendWithMask")!
        bloomFilter.setValue(hazedImage,    forKey: kCIInputBackgroundImageKey)
        bloomFilter.setValue(clampedBlur,   forKey: kCIInputImageKey)
        bloomFilter.setValue(luminanceMask, forKey: kCIInputMaskImageKey)
        guard let bloomedImage = bloomFilter.outputImage else { return hazedImage }

        // Step 4: わずかに黄みを加える（加齢による水晶体の黄変）
        // 赤・緑をわずかに上げ、青を少し下げることで黄みがかった色調に
        let yellowTintStrength = CGFloat(mix(0.0, 0.05, t: intensity))
        let tintFilter = CIFilter.colorMatrix()
        tintFilter.inputImage = bloomedImage
        // 単位行列にわずかな黄み調整を加える
        tintFilter.rVector = CIVector(x: 1.0, y: 0, z: 0, w: 0)
        tintFilter.gVector = CIVector(x: 0, y: 1.0, z: 0, w: 0)
        tintFilter.bVector = CIVector(x: 0, y: 0, z: max(0, 1.0 - yellowTintStrength * 2), w: 0)
        // biasVector で全体に黄みをプラス（R+, G+, B-）
        tintFilter.biasVector = CIVector(
            x: yellowTintStrength,
            y: yellowTintStrength * 0.5,
            z: 0,
            w: 0
        )

        return tintFilter.outputImage ?? bloomedImage
    }

    // ------------------------------------------------------------------
    // 網膜色素変性症フィルター（周辺視野の暗化 + トンネル視野）
    //
    // 【網膜色素変性症の視覚的特徴】
    // ・網膜周辺部の光受容細胞（桿体細胞）が先に壊れる
    // ・周辺視野から徐々に暗くなり（夜盲）、最終的に管状視野になる
    // ・視野狭窄（緑内障）との違い：より強い暗化、コントラスト低下
    // ・境界は視野狭窄より鮮明（より「壁」的な暗部）
    //
    // 【視野狭窄との実装上の違い】
    // 視野狭窄（CIVignetteEffect）: 周辺がグレーに暗くなる
    // 網膜色素変性症:              周辺が真っ黒になる + コントラスト全体低下
    //
    // 【実装：2段階】
    // 1. CIColorControls: コントラスト低下（暗部がより暗くなる）
    // 2. CIRadialGradient + CIBlendWithMask:
    //    中心は明るく、周辺は真っ黒のマスクを生成してトンネル視野を表現
    // ------------------------------------------------------------------
    private func applyRetinitisFilter(to image: CIImage, intensity: Float) -> CIImage {
        guard intensity > 0.01 else { return image }

        let width  = image.extent.width
        let height = image.extent.height
        let center = CIVector(x: width / 2, y: height / 2)

        // Step 1: コントラスト低下と暗化（網膜の感度低下を表現）
        // 健常者より全体的にコントラストが落ちて見える
        let contrastFilter = CIFilter.colorControls()
        contrastFilter.inputImage  = image
        contrastFilter.contrast    = mix(1.0, 0.7, t: intensity)
        contrastFilter.brightness  = mix(0.0, -0.08, t: intensity)  // わずかに暗く
        contrastFilter.saturation  = mix(1.0, 0.8, t: intensity)    // 色も少し薄れる
        guard let contrastedImage = contrastFilter.outputImage else { return image }

        // Step 2: 放射状グラデーションマスクで周辺を真っ黒にする
        //
        // CIRadialGradient:
        //   中心から radius0（完全に明るい = 白）まで白
        //   radius0 から radius1 の間でグラデーション
        //   radius1 以降は完全に黒 = 視野外
        //
        // 視野狭窄と違いグラデーション幅を狭くして「壁」感を出す
        let shortSide = Float(min(width, height))
        // 中心の明るい視野の半径
        // intensity=0.0: 短辺の 65%（広い視野）
        // intensity=1.0: 短辺の  8%（重度のトンネル視野）
        let innerRadius = shortSide * mix(0.65, 0.08, t: intensity)
        // 暗化が完了する外側の半径（内側から短辺の 15% 分でグラデーション）
        // 視野狭窄より狭いグラデーション幅 = より「壁」的な境界
        let outerRadius = innerRadius + shortSide * mix(0.25, 0.05, t: intensity)

        // 放射状グラデーション（白→黒）を生成
        // center, radius0（白の終端）, radius1（黒の始端）を指定
        let gradientFilter = CIFilter(name: "CIRadialGradient")!
        gradientFilter.setValue(center,             forKey: "inputCenter")
        gradientFilter.setValue(innerRadius,        forKey: "inputRadius0")
        gradientFilter.setValue(outerRadius,        forKey: "inputRadius1")
        gradientFilter.setValue(CIColor.white,      forKey: "inputColor0")  // 中心：白（視野あり）
        gradientFilter.setValue(CIColor.black,      forKey: "inputColor1")  // 外周：黒（視野なし）
        guard let gradientImage = gradientFilter.outputImage else { return contrastedImage }

        // グラデーションを画像サイズにクロップ
        let mask = gradientImage.cropped(to: image.extent)

        // Step 3: マスクを使って中心は元画像、周辺は黒を合成
        // CIBlendWithMask: maskImage が白い部分 → inputImage（コントラスト低下画像）
        //                  maskImage が黒い部分 → backgroundImage（真っ黒）
        let blackBackground = CIImage(color: CIColor.black).cropped(to: image.extent)
        let blendFilter = CIFilter(name: "CIBlendWithMask")!
        blendFilter.setValue(blackBackground,   forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(contrastedImage,   forKey: kCIInputImageKey)
        blendFilter.setValue(mask,              forKey: kCIInputMaskImageKey)

        return blendFilter.outputImage ?? contrastedImage
    }

    // ------------------------------------------------------------------
    // 老眼フィルター（近距離のぼかし）
    //
    // 【老眼の視覚的特徴】
    // ・水晶体の弾力が失われ、近距離にピントが合わなくなる
    // ・遠くはほぼ正常に見えるが、手元がぼやける
    // ・全体的なぼかしではなく、「ピントが合っていない」質感
    //
    // 【実装】
    // 1. CIGaussianBlur: 全体をぼかす
    // 2. CIVibrance/CIColorControls: コントラストをやや落とす（目の疲れ感）
    // ※ 本来は近距離だけがぼける。空間写真全体に適用するのは近似的表現。
    // ------------------------------------------------------------------
    private func applyPresbyopiaFilter(to image: CIImage, intensity: Float) -> CIImage {
        guard intensity > 0.01 else { return image }

        let width  = image.extent.width
        let height = image.extent.height

        // Step 1: ガウスぼかし
        // radius: intensity=1.0 で短辺の 2.0%（老眼らしいふんわりぼかし）
        // 白内障より少し小さめのぼかし（ハレーション効果なし）
        let blurRadius = Float(min(width, height)) * mix(0.0, 0.02, t: intensity)
        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = image
        blurFilter.radius     = blurRadius
        guard let blurredImage = blurFilter.outputImage else { return image }

        // ぼかしで広がったはみ出し部分を元のサイズにクロップ
        let clampedBlur = blurredImage.cropped(to: image.extent)

        // Step 2: コントラストをやや落とす（長時間ピントを合わせようとする疲れ感）
        // 白内障の霞みより軽め。「ぼやけている」だけでなく「疲れ目」感を加える
        let controlsFilter = CIFilter.colorControls()
        controlsFilter.inputImage  = clampedBlur
        controlsFilter.contrast    = mix(1.0, 0.88, t: intensity)
        controlsFilter.brightness  = mix(0.0, 0.02, t: intensity)  // わずかに明るく（眩しさ）
        controlsFilter.saturation  = mix(1.0, 0.92, t: intensity)  // ごくわずかに彩度低下

        return controlsFilter.outputImage ?? clampedBlur
    }

    // ------------------------------------------------------------------
    // 乱視フィルター（方向性のあるブレ）
    //
    // 【乱視の視覚的特徴】
    // ・角膜・水晶体のゆがみにより、光が一点に集まらない
    // ・特定方向に像が二重に（または引き伸ばされて）見える
    // ・夜間や光源周辺で特に顕著（光がにじむ）
    // ・水平方向の乱視が最も一般的（斜めも存在）
    //
    // 【白内障との違い】
    // 白内障：全方向に均等なぼかし（光が散乱）
    // 乱視：  特定方向へのブレ（光が伸びる）
    //
    // 【実装】
    // CIMotionBlur: 指定した角度方向にモーションブラーをかける
    // angle: π/6 ≈ 30度（斜め方向の乱視を表現）
    // ------------------------------------------------------------------
    private func applyAstigmatismFilter(to image: CIImage, intensity: Float) -> CIImage {
        guard intensity > 0.01 else { return image }

        let width  = image.extent.width
        let height = image.extent.height

        // Step 1: モーションブラー（方向性のあるブレ）
        // radius: intensity=1.0 で短辺の 1.5%（視野全体に方向性のあるブレ）
        // angle: π/6（30度斜め）= 最も一般的な水平・斜め方向の乱視に近い角度
        let blurRadius = Float(min(width, height)) * mix(0.0, 0.015, t: intensity)
        let motionFilter = CIFilter(name: "CIMotionBlur")!
        motionFilter.setValue(image, forKey: kCIInputImageKey)
        motionFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
        motionFilter.setValue(Float.pi / 6.0, forKey: kCIInputAngleKey)  // 30度
        guard let motionBlurred = motionFilter.outputImage else { return image }

        // ブラーによるはみ出し部分を元のサイズにクロップ
        let clampedMotion = motionBlurred.cropped(to: image.extent)

        // Step 2: ハロー感の強調（光源が伸びる乱視の特徴）
        // 元画像の明るい部分だけをモーションブラー後の画像に少し重ねる
        // → 光源周辺だけが特定方向に「にじむ」効果
        let luminanceMask = image
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,  // グレースケール化
                kCIInputContrastKey: 2.5,    // コントラスト強調（明部だけを抽出）
                kCIInputBrightnessKey: -0.2  // 暗部をさらに暗くし明部だけ残す
            ])

        // 明るい部分（光源）のみモーションブラー版を重ねる
        let bloomBlend = CIFilter(name: "CIBlendWithMask")!
        bloomBlend.setValue(clampedMotion,  forKey: kCIInputBackgroundImageKey)
        bloomBlend.setValue(clampedMotion,  forKey: kCIInputImageKey)
        bloomBlend.setValue(luminanceMask,  forKey: kCIInputMaskImageKey)

        // Step 3: コントラスト微調整（ピントが合っていない疲れ感）
        let controlsFilter = CIFilter.colorControls()
        controlsFilter.inputImage  = bloomBlend.outputImage ?? clampedMotion
        controlsFilter.contrast    = mix(1.0, 0.90, t: intensity)
        controlsFilter.brightness  = 0
        controlsFilter.saturation  = mix(1.0, 0.95, t: intensity)

        return controlsFilter.outputImage ?? clampedMotion
    }

    // ------------------------------------------------------------------
    // ARKit ワールドトラッキング開始
    //
    // WorldTrackingProvider を使ってヘッドの向きを毎フレーム取得し、
    // ドームのUV座標（視線の正規化位置）に変換して AppModel に保存する。
    //
    // 【変換の仕組み】
    // DeviceAnchor.originFromAnchorTransform は 4x4 行列。
    // 3列目（columns.2）は「Z軸の向き」= ヘッドの「後ろ方向」。
    // ヘッドの「前方向」は -Z なので、columns.2 に -1 をかける。
    //
    // その前方ベクトル (x, y, z) をドームのUV座標に変換：
    //   u = 0.5 + atan2(x, -z) / (2π)
    //   v = 0.5 - asin(y) / π
    //
    // 【スムージング】
    // 生の視線をそのまま使うと中心暗点が震えて見える。
    // 前フレームの値と lerp でスムージングする（α = 0.15）。
    // ------------------------------------------------------------------
    @MainActor
    private func startARKitTracking() async {
        do {
            try await arkitSession.run([worldTracking])
            print("✅ ARKitSession 開始")
        } catch {
            print("⚠️ ARKitSession 開始失敗: \(error)")
            return
        }

        // 毎フレーム（約 60fps）ヘッドの向きを取得してガze位置を更新
        // Task.sleep で 16ms（約 60fps）間隔でポーリングする
        while !Task.isCancelled {
            // 現在のタイムスタンプでデバイスアンカーを取得
            if let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
                let matrix = anchor.originFromAnchorTransform

                // ヘッドの前方ベクトル（-Z 軸）を抽出
                // columns.2 は Z 軸の向き（後ろ向き）なので符号を反転
                let forward = SIMD3<Float>(
                    -matrix.columns.2.x,
                    -matrix.columns.2.y,
                    -matrix.columns.2.z
                )

                // 球面上のUV座標に変換（0.0〜1.0 の正規化座標）
                // u: 水平方向（左右）= atan2(x, -z) / (2π) + 0.5
                // v: 垂直方向（上下）= 0.5 - asin(y) / π
                let u = 0.5 + atan2f(forward.x, -forward.z) / (2.0 * Float.pi)
                let v = 0.5 - asinf(max(-1.0, min(1.0, forward.y))) / Float.pi
                let rawGaze = SIMD2<Float>(u, v)

                // スムージング（lerp α = 0.15）
                // 急な動きは追従しすぎず、緩やかな動きはスムーズに追う
                let alpha: Float = 0.15
                let smoothed = mix(appModel.gazeNormalized, rawGaze, t: alpha)
                appModel.gazeNormalized = smoothed
            }

            // 約 60fps でポーリング（16ms）
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    // ------------------------------------------------------------------
    // 中心暗点フィルター（黄斑変性などで中心視野が欠けた状態）
    //
    // 【中心暗点の視覚的特徴】
    // ・視線の中心（fovea）が欠けて見えなくなる
    // ・欠けた部分は暗く（または無）なり、周辺視野は保たれる
    // ・視線を向けた先が「消える」ため、読書や顔認識が困難
    //
    // 【アイトラッキング連動】
    // center パラメータが視線の正規化UV座標 (0.0〜1.0)。
    // (0.5, 0.5) = 画像中央 = まっすぐ前を見ているとき。
    //
    // 【実装】
    // CIRadialGradient でマスクを生成：
    //   中心（視線位置）は黒（視野なし）、外側は白（視野あり）
    // CIBlendWithMask で元画像と黒背景を合成する。
    // ------------------------------------------------------------------
    private func applyScotomaFilter(
        to image: CIImage,
        intensity: Float,
        center: SIMD2<Float>
    ) -> CIImage {
        guard intensity > 0.01 else { return image }

        let width  = image.extent.width
        let height = image.extent.height

        // 視線位置をピクセル座標に変換
        // CIImage の座標は左下原点なので Y を反転する
        let cx = CGFloat(center.x) * width
        let cy = (1.0 - CGFloat(center.y)) * height
        let ciCenter = CIVector(x: cx, y: cy)

        let shortSide = Float(min(width, height))

        // 中心の「見えない領域」の半径
        // intensity=0.0（最小）: 短辺の 5%（わずかなぼやけ）
        // intensity=1.0（最大）: 短辺の 25%（重度の中心暗点）
        let innerRadius = shortSide * mix(0.05, 0.25, t: intensity)
        // 暗化が完了する外側の半径（なだらかなグラデーション境界）
        let outerRadius = innerRadius + shortSide * 0.10

        // 放射状グラデーション：中心 = 黒（視野なし）、外側 = 白（視野あり）
        // ※ 通常の視野狭窄と逆（内側が黒）
        let gradientFilter = CIFilter(name: "CIRadialGradient")!
        gradientFilter.setValue(ciCenter,       forKey: "inputCenter")
        gradientFilter.setValue(innerRadius,    forKey: "inputRadius0")
        gradientFilter.setValue(outerRadius,    forKey: "inputRadius1")
        gradientFilter.setValue(CIColor.black,  forKey: "inputColor0")  // 中心：黒（見えない）
        gradientFilter.setValue(CIColor.white,  forKey: "inputColor1")  // 外周：白（見える）
        guard let gradientImage = gradientFilter.outputImage else { return image }

        let mask = gradientImage.cropped(to: image.extent)

        // マスクを使って中心は黒、周辺は元画像を表示
        let blackBackground = CIImage(color: CIColor.black).cropped(to: image.extent)
        let blendFilter = CIFilter(name: "CIBlendWithMask")!
        blendFilter.setValue(blackBackground, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(image,           forKey: kCIInputImageKey)
        blendFilter.setValue(mask,            forKey: kCIInputMaskImageKey)

        return blendFilter.outputImage ?? image
    }

    // ------------------------------------------------------------------
    // 飛蚊症フィルター（硝子体の混濁による影）
    //
    // 【飛蚊症の視覚的特徴】
    // ・視界に糸状・点状・輪状の半透明な影が浮いて見える
    // ・視線を動かすと少し遅れて動く（硝子体と一緒に揺れる）
    // ・明るい均一な背景（空・白壁）で特に目立つ
    // ・加齢や近視が原因のことが多い
    //
    // 【アイトラッキング連動】
    // center パラメータを基準に影の位置を決定する。
    // 視線が動くと影もゆっくり追従する（スムージングは AppModel 側）。
    //
    // 【実装】
    // CIRadialGradient で複数の半透明な楕円形の影を生成し、
    // CISourceOverCompositing で元画像に重ねる。
    // 影の位置は center からのオフセットで決まる（固定シード）。
    // ------------------------------------------------------------------
    private func applyFloatersFilter(
        to image: CIImage,
        intensity: Float,
        center: SIMD2<Float>,
        floatersType: FloatersType = .granular
    ) -> CIImage {
        guard intensity > 0.01 else { return image }

        let width     = image.extent.width
        let height    = image.extent.height
        let shortSide = Float(min(width, height))

        // intensity に応じてサイズ・濃さをスケール
        let sizeScale  = mix(0.6, 1.4, t: intensity)
        let alphaScale = mix(0.4, 1.0, t: intensity)

        // 透明な重ね合わせベース画像
        var overlayImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: image.extent)

        switch floatersType {

        // ------------------------------------------------------------------
        // ゴマ状：小さな丸い点が複数浮かぶ
        // 硝子体の変性による微細な混濁。最も一般的な飛蚊症。
        // ------------------------------------------------------------------
        case .granular:
            // (offsetX, offsetY, radiusScale, alpha)
            let defs: [(Float, Float, Float, Float)] = [
                ( 0.04,  0.07, 0.018, 0.55),
                (-0.09,  0.02, 0.013, 0.45),
                ( 0.12, -0.05, 0.016, 0.50),
                (-0.03,  0.13, 0.011, 0.40),
                ( 0.06, -0.11, 0.015, 0.48),
                (-0.14,  0.09, 0.012, 0.42),
                ( 0.09,  0.16, 0.010, 0.38),
            ]
            for (ox, oy, rs, a) in defs {
                let fx     = CGFloat(center.x + ox) * width
                let fy     = (1.0 - CGFloat(center.y + oy)) * height
                let r      = CGFloat(shortSide) * CGFloat(rs * sizeScale)
                let alpha  = CGFloat(min(1.0, a * alphaScale))
                overlayImage = addCircleSpot(
                    to: overlayImage, extent: image.extent,
                    cx: fx, cy: fy,
                    innerRadius: r, outerRadius: r * 1.5,
                    alpha: alpha
                )
            }

        // ------------------------------------------------------------------
        // 虫状：横長の楕円が数個浮かぶ
        // CGContext でベジェ楕円を描き、CIImage に変換して重ねる。
        // CIRadialGradient は真円のみなので CGContext を使う必要がある。
        // ------------------------------------------------------------------
        case .worm:
            let defs: [(ox: Float, oy: Float, wScale: Float, hScale: Float, angle: Double, alpha: Float)] = [
                ( 0.05,  0.07, 0.10, 0.025, -15, 0.58),
                (-0.10,  0.03, 0.08, 0.020,  20, 0.48),
                ( 0.12, -0.06, 0.09, 0.022,  -5, 0.52),
                (-0.04,  0.14, 0.07, 0.018,  30, 0.44),
            ]
            for def in defs {
                let cx    = CGFloat(center.x + def.ox) * width
                let cy    = (1.0 - CGFloat(center.y + def.oy)) * height
                let w     = CGFloat(shortSide) * CGFloat(def.wScale * sizeScale)
                let h     = CGFloat(shortSide) * CGFloat(def.hScale * sizeScale)
                let alpha = CGFloat(min(1.0, def.alpha * alphaScale))
                if let ciEllipse = makeEllipseCIImage(
                    extent: image.extent,
                    cx: cx, cy: cy, w: w, h: h,
                    angleDeg: def.angle, alpha: alpha
                ) {
                    overlayImage = composite(ciEllipse, over: overlayImage)
                }
            }

        // ------------------------------------------------------------------
        // カエルの卵状：輪っか（ドーナツ形）が浮かぶ
        // 外側の円から内側の透明円を引いてリング形状を作る。
        // CIRadialGradient の color0（内側）を透明にすると実現できる。
        // ------------------------------------------------------------------
        case .egg:
            let defs: [(Float, Float, Float, Float)] = [
                ( 0.05,  0.08, 0.040, 0.55),
                (-0.11,  0.04, 0.030, 0.48),
                ( 0.13, -0.07, 0.035, 0.52),
                (-0.03,  0.16, 0.025, 0.42),
            ]
            for (ox, oy, rs, a) in defs {
                let fx    = CGFloat(center.x + ox) * width
                let fy    = (1.0 - CGFloat(center.y + oy)) * height
                let outer = CGFloat(shortSide) * CGFloat(rs * sizeScale)
                let inner = outer * 0.55  // リングの穴のサイズ（55%）
                let alpha = CGFloat(min(1.0, a * alphaScale))
                overlayImage = addRingSpot(
                    to: overlayImage, extent: image.extent,
                    cx: fx, cy: fy,
                    innerHoleRadius: inner,
                    ringOuterRadius: outer,
                    edgeFade: outer * 0.15,
                    alpha: alpha
                )
            }
        }

        // 影レイヤーを元画像の上に重ねる
        return composite(overlayImage, over: image)
    }

    // ------------------------------------------------------------------
    // ヘルパー：円形スポット（ゴマ状用）
    // CIRadialGradient で内側が濃く外側が透明になる円を生成する
    // ------------------------------------------------------------------
    private func addCircleSpot(
        to base: CIImage, extent: CGRect,
        cx: CGFloat, cy: CGFloat,
        innerRadius: CGFloat, outerRadius: CGFloat,
        alpha: CGFloat
    ) -> CIImage {
        let f = CIFilter(name: "CIRadialGradient")!
        f.setValue(CIVector(x: cx, y: cy), forKey: "inputCenter")
        f.setValue(innerRadius,            forKey: "inputRadius0")
        f.setValue(outerRadius,            forKey: "inputRadius1")
        f.setValue(CIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: alpha),
                   forKey: "inputColor0")
        f.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0),
                   forKey: "inputColor1")
        guard let spot = f.outputImage?.cropped(to: extent) else { return base }
        return composite(spot, over: base)
    }

    // ------------------------------------------------------------------
    // ヘルパー：リング形状（カエルの卵状用）
    // 2つの CIRadialGradient を組み合わせてドーナツ形を作る。
    // 外側グラデーション（輪の外縁）から内側穴（透明）を CIBlendWithMask で切り抜く。
    // ------------------------------------------------------------------
    private func addRingSpot(
        to base: CIImage, extent: CGRect,
        cx: CGFloat, cy: CGFloat,
        innerHoleRadius: CGFloat,   // 穴の半径
        ringOuterRadius: CGFloat,   // 輪の外縁半径
        edgeFade: CGFloat,          // 外縁のフェード幅
        alpha: CGFloat
    ) -> CIImage {
        let center = CIVector(x: cx, y: cy)

        // 輪本体（外縁グラデーション）：外側が透明、内側が濃い
        let outerF = CIFilter(name: "CIRadialGradient")!
        outerF.setValue(center,            forKey: "inputCenter")
        outerF.setValue(ringOuterRadius - edgeFade, forKey: "inputRadius0")
        outerF.setValue(ringOuterRadius,   forKey: "inputRadius1")
        outerF.setValue(CIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: alpha),
                        forKey: "inputColor0")
        outerF.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0),
                        forKey: "inputColor1")

        // 穴マスク：中心が白（穴あり）、外側が黒（穴なし）= 反転マスク
        // → 中心部分を「見えなくする」マスクとして使う
        let holeF = CIFilter(name: "CIRadialGradient")!
        holeF.setValue(center,          forKey: "inputCenter")
        holeF.setValue(innerHoleRadius * 0.7, forKey: "inputRadius0")
        holeF.setValue(innerHoleRadius, forKey: "inputRadius1")
        holeF.setValue(CIColor.white,   forKey: "inputColor0")  // 穴の中心 = 白（切り抜く）
        holeF.setValue(CIColor.black,   forKey: "inputColor1")  // 外側 = 黒（切り抜かない）

        guard let outerImage = outerF.outputImage?.cropped(to: extent),
              let holeMask   = holeF.outputImage?.cropped(to: extent) else { return base }

        // CIBlendWithMask: holeMask が白いところ（穴）は background（透明）を使う
        // → 輪の中央を透明にして「ドーナツ形」にする
        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: extent)
        let cutFilter = CIFilter(name: "CIBlendWithMask")!
        cutFilter.setValue(outerImage,   forKey: kCIInputBackgroundImageKey)
        cutFilter.setValue(transparent,  forKey: kCIInputImageKey)
        cutFilter.setValue(holeMask,     forKey: kCIInputMaskImageKey)
        guard let ring = cutFilter.outputImage else { return base }

        return composite(ring, over: base)
    }

    // ------------------------------------------------------------------
    // ヘルパー：CGContext で楕円を描き CIImage に変換（虫状用）
    //
    // CIRadialGradient は真円しか描けないため、
    // 楕円が必要な虫状は CGContext（通常の2D描画API）を使う。
    //
    // 【React Native との対比】
    // HTML Canvas の ctx.ellipse() に相当するが、
    // Swift では CGContext + CGPath を使う。
    // ------------------------------------------------------------------
    private func makeEllipseCIImage(
        extent: CGRect,
        cx: CGFloat, cy: CGFloat,
        w: CGFloat, h: CGFloat,       // 楕円の横幅・縦幅
        angleDeg: Double,             // 回転角度（度数法）
        alpha: CGFloat
    ) -> CIImage? {
        let intW = Int(extent.width)
        let intH = Int(extent.height)
        guard intW > 0, intH > 0 else { return nil }

        // RGBA 8bit のピクセルバッファを確保
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: intW, height: intH,
            bitsPerComponent: 8,
            bytesPerRow: intW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 描画スタイル：半透明の濃いグレー、フェードエッジのためにぼかし
        ctx.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.15, alpha: alpha))
        ctx.setShadow(offset: .zero, blur: h * 0.5)  // 楕円エッジをぼかす

        // 楕円の中心を原点に移動 → 回転 → 楕円描画 → 元に戻す
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: CGFloat(angleDeg * Double.pi / 180.0))
        ctx.fillEllipse(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        ctx.restoreGState()

        guard let cgImage = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    // ------------------------------------------------------------------
    // ヘルパー：CISourceOverCompositing の共通処理
    // ------------------------------------------------------------------
    private func composite(_ top: CIImage, over bottom: CIImage) -> CIImage {
        let f = CIFilter(name: "CISourceOverCompositing")!
        f.setValue(top,    forKey: kCIInputImageKey)
        f.setValue(bottom, forKey: kCIInputBackgroundImageKey)
        return f.outputImage ?? bottom
    }

    // ------------------------------------------------------------------
    // 線形補間ヘルパー（mix: a→b を t=0.0〜1.0 で補間）
    // SIMD2<Float> 版と Float 版の両方を用意する
    // ------------------------------------------------------------------
    private func mix(_ a: SIMD2<Float>, _ b: SIMD2<Float>, t: Float) -> SIMD2<Float> {
        return a + (b - a) * t
    }

    // ------------------------------------------------------------------
    // 線形補間ヘルパー（mix: a→b を t=0.0〜1.0 で補間）
    // ------------------------------------------------------------------
    private func mix(_ a: Float, _ b: Float, t: Float) -> Float {
        return a + (b - a) * t
    }
}

#Preview(immersionStyle: .full) {
    ImmersiveView()
        .environment(AppModel())
}
