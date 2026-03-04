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
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
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
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
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
    //   radius: 明るい中心の半径（小さいほど視野が狭い）
    //   intensity: 暗さ（1.0 = 完全に黒）
    //   falloff: 境界のなだらかさ（大きいほどぼんやり）
    // ------------------------------------------------------------------
    private func applyVignetteFilter(to image: CIImage, intensity: Float) -> CIImage {
        let width  = image.extent.width
        let height = image.extent.height

        // 画像の中心を視野の中心として設定
        let center = CGPoint(x: width / 2, y: height / 2)

        // 「明るい中心の半径」を intensity に応じて変える
        // intensity=0.0（軽度）: 画像の 45% が明るいゾーン
        // intensity=1.0（重度）: 画像の 10% が明るいゾーン
        // 画像の短辺の半分を基準にする（長方形でも均等に見える）
        let baseRadius = Float(min(width, height)) / 2.0
        let radius = baseRadius * mix(0.45, 0.10, t: intensity)

        let filter = CIFilter.vignetteEffect()
        filter.inputImage  = image
        filter.center      = center
        filter.radius      = radius
        filter.intensity   = 1.5  // 固定：十分暗くする
        filter.falloff     = mix(0.5, 0.15, t: intensity)  // 重いほど境界がシャープ

        return filter.outputImage ?? image
    }

    // ------------------------------------------------------------------
    // 色覚異常フィルター（CIColorMatrix による変換）
    //
    // 【RGB変換行列について】
    // CIColorMatrix は [R, G, B, A] → [R', G', B', A'] の線形変換。
    // rVector = 出力 R' を計算するときの [入力R, G, B, A] の係数。
    //
    // intensity=0.0 → 単位行列（変換なし）
    // intensity=1.0 → 完全変換
    // ------------------------------------------------------------------
    private func applyColorBlindFilter(
        to image: CIImage,
        type: ColorBlindType,
        intensity: Float
    ) -> CIImage {

        // 各タイプの完全変換行列（intensity=1.0 時に適用される値）
        let (rVec, gVec, bVec): (CIVector, CIVector, CIVector)

        switch type {
        case .deuteranopia:
            // 2型色覚（緑弱）: M錐体（緑感受性）が欠損
            // 赤と緑を区別しにくい。「赤と緑が似た色に見える」
            rVec = CIVector(x: 0.625, y: 0.375, z: 0.0, w: 0.0)
            gVec = CIVector(x: 0.700, y: 0.300, z: 0.0, w: 0.0)
            bVec = CIVector(x: 0.000, y: 0.300, z: 0.700, w: 0.0)

        case .protanopia:
            // 1型色覚（赤弱）: L錐体（赤感受性）が欠損
            // 赤が暗く見え、赤緑を区別しにくい
            rVec = CIVector(x: 0.567, y: 0.433, z: 0.0, w: 0.0)
            gVec = CIVector(x: 0.558, y: 0.442, z: 0.0, w: 0.0)
            bVec = CIVector(x: 0.000, y: 0.242, z: 0.758, w: 0.0)

        case .tritanopia:
            // 3型色覚（青弱）: S錐体（青感受性）が欠損
            // 青と緑、黄と赤の区別が難しい（日本人には稀）
            rVec = CIVector(x: 0.950, y: 0.050, z: 0.0, w: 0.0)
            gVec = CIVector(x: 0.000, y: 0.433, z: 0.567, w: 0.0)
            bVec = CIVector(x: 0.000, y: 0.475, z: 0.525, w: 0.0)
        }

        // intensity で単位行列と変換行列を補間
        let t = CGFloat(intensity)
        func lerp(_ identity: CIVector, _ target: CIVector) -> CIVector {
            CIVector(
                x: identity.x * (1 - t) + target.x * t,
                y: identity.y * (1 - t) + target.y * t,
                z: identity.z * (1 - t) + target.z * t,
                w: identity.w * (1 - t) + target.w * t
            )
        }

        let filter = CIFilter.colorMatrix()
        filter.inputImage  = image
        filter.rVector     = lerp(CIVector(x: 1, y: 0, z: 0, w: 0), rVec)
        filter.gVector     = lerp(CIVector(x: 0, y: 1, z: 0, w: 0), gVec)
        filter.bVector     = lerp(CIVector(x: 0, y: 0, z: 1, w: 0), bVec)
        filter.aVector     = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector  = CIVector(x: 0, y: 0, z: 0, w: 0)

        return filter.outputImage ?? image
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
