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

    // ドームEntityへの参照を保持
    @State private var domeEntity: ModelEntity? = nil

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
            if let panelEntity = attachments.entity(for: panelAttachmentID) {
                panelEntity.position = SIMD3<Float>(0, 0.6, -1.2)
                content.add(panelEntity)
            }

        } attachments: {
            Attachment(id: panelAttachmentID) {
                @Bindable var model = appModel
                FloatingPanelView(conditionSetting: $model.conditionSetting)
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
