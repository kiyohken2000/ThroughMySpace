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
