// ImmersiveView.swift
// ThroughMySpace
//
// Full Immersion Space の本体。
// 前方ドームメッシュに空間写真を表示し、
// 症状選択パネルを空間内に浮かべる。
//
// 【visionOS のマテリアル制約について】
// visionOS では CustomMaterial（Metal シェーダー直書き）が使用不可。
//
// 【採用した方針：CPU フィルタリング + ShaderGraphMaterial（立体視対応）】
// Core Image を使って視野狭窄・色覚異常フィルターを Swift 側で適用し、
// 処理済みの画像を TextureResource として ShaderGraphMaterial の
// LeftTexture / RightTexture に渡す。
// ShaderGraphMaterial の CameraIndexSwitch ノードが左右目に
// 別々のテクスチャを表示することで立体感を維持する。
//
// 【パフォーマンス設計】
// ・写真の CGImage 抽出（重い処理）は初回のみ → AppModel.sourceStereoImages に保存
// ・症状変更時はその CGImage にフィルターをかけるだけ（軽い処理）
// これにより強度スライダーの変更がスムーズに反映される。

import SwiftUI
import RealityKit
import RealityKitContent
import CoreImage
import CoreImage.CIFilterBuiltins
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

    // Core Image のコンテキスト（再生成を避けるために保持）
    @State private var ciContext = CIContext()

    // 現在処理中のフィルタータスク（連打時に前のタスクをキャンセルするため）
    @State private var filterTask: Task<Void, Never>? = nil

    // ------------------------------------------------------------------
    // ARKit セッション（ヘッドトラッキング用）
    //
    // WorldTrackingProvider でヘッドの向きを毎フレーム取得する。
    // visionOS の Full Immersive Space では追加権限なしで利用できる。
    //
    // 【React Native との対比】
    // iOS の ARSession に相当するが、visionOS では ARKitSession を使う。
    // ------------------------------------------------------------------
    @State private var arkitSession   = ARKitSession()
    @State private var worldTracking  = WorldTrackingProvider()

    // ------------------------------------------------------------------
    // Entity オーバーレイ方式（中心暗点・飛蚊症）
    //
    // Core Image フィルターは毎フレームのテクスチャ再生成が必要で重すぎる。
    // 代わりに RealityKit の ModelEntity をドームの球面上に配置し、
    // ヘッドの向きに応じて毎フレーム position を更新するだけで対応する。
    // テクスチャは起動時に一度だけ生成する（ゴマ状・虫状・卵状も含む）。
    // ------------------------------------------------------------------

    /// 中心暗点オーバーレイ（単一の黒円）
    @State private var scotomaEntity: ModelEntity? = nil

    /// 視野狭窄オーバーレイ（周辺を暗くするドーナツ状リング）
    @State private var visualFieldEntity: ModelEntity? = nil

    /// 網膜色素変性症オーバーレイ（より暗く急峻な境界のドーナツ状リング）
    @State private var retinitisEntity: ModelEntity? = nil

    /// 飛蚊症オーバーレイ（ゴマ状のみ）
    @State private var floaterEntitiesByType: [[ModelEntity]] = []

    /// 現在表示中の飛蚊症タイプのEntityリスト（更新の便利のため）
    @State private var floaterEntities: [ModelEntity] = []

    /// ドームの半径（makeContentと同じ値）
    private let domeRadius: Float = 3.0

    /// Entity をヘッドの前方に配置する距離。
    /// ドーム半径(3.0m)より大幅に手前にすることで：
    /// 1. ドームメッシュとの交差・クリッピングを防ぐ
    /// 2. 上/下/横など任意の向きでもドーム範囲外に出ず常に見える
    private let overlayDistance: Float = 1.5

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

            // MARK: 中心暗点オーバーレイ Entity（初期は非表示）
            let scotoma = makeScotomaEntity()
            scotoma.isEnabled = false
            content.add(scotoma)
            scotomaEntity = scotoma

            // MARK: 視野狭窄オーバーレイ Entity（初期は非表示）
            let vf = makeVisualFieldEntity()
            vf.isEnabled = false
            content.add(vf)
            visualFieldEntity = vf

            // MARK: 網膜色素変性症オーバーレイ Entity（初期は非表示）
            let rp = makeRetinitisEntity()
            rp.isEnabled = false
            content.add(rp)
            retinitisEntity = rp

            // MARK: 飛蚊症オーバーレイ Entity（ゴマ状のみ、初期は非表示）
            let granularEntities = makeFloaterEntities()
            for e in granularEntities {
                e.isEnabled = false
                content.add(e)
            }
            floaterEntitiesByType = [granularEntities]
            floaterEntities = granularEntities

            // MARK: フローティングパネルを 3D 空間に配置
            // 少し上（y=0.6）・正面方向（z=-1.2）に浮かせる
            if let panelEntity = attachments.entity(for: panelAttachmentID) {
                panelEntity.position = SIMD3<Float>(0, 0.6, -0.8)
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
        // 写真が変わったとき：マテリアルを再適用する
        .onChange(of: appModel.textureVersion) { _, _ in
            guard let dome = domeEntity else { return }
            filterTask?.cancel()
            filterTask = Task { @MainActor in
                await applyMaterial(to: dome,
                                    textures: appModel.selectedStereoTextures,
                                    setting: appModel.conditionSetting)
            }
        }
        // 症状設定が変わったとき：保存済み CGImage にフィルターをかけ直す
        .onChange(of: appModel.conditionSetting) { oldSetting, newSetting in
            // ──────────────────────────────────────────────
            // Entity オーバーレイの表示切り替え
            // （中心暗点・飛蚊症・視野狭窄・網膜色素変性症）
            // ──────────────────────────────────────────────
            let isScotoma      = (newSetting.type == .scotoma)
            let isFloaters     = (newSetting.type == .floaters)
            let isVisualField  = (newSetting.type == .visualField)
            let isRetinitis    = (newSetting.type == .retinitispigmentosa)

            // 中心暗点：表示/非表示 + intensity に応じたスケール更新
            // ベースサイズ 0.6m（overlayDistance=1.5m 基準）
            // intensity=0（軽度）: スケール 0.6 → 0.36m（小さな暗点）
            // intensity=1（重度）: スケール 2.2 → 1.32m（広い暗点）
            if let scotoma = scotomaEntity {
                scotoma.isEnabled = isScotoma
                if isScotoma {
                    let scotomaScale = mix(0.6, 2.2, t: newSetting.intensity.value)
                    scotoma.scale = SIMD3<Float>(scotomaScale, scotomaScale, scotomaScale)
                }
            }

            // 視野狭窄：表示/非表示 + intensity に応じたスケール更新
            // intensity=0（軽度）: スケール 0.8（周辺がわずかに暗い）
            // intensity=1（重度）: スケール 2.8（ほぼ全視野が暗化）
            if let vf = visualFieldEntity {
                vf.isEnabled = isVisualField
                if isVisualField {
                    let vfScale = mix(0.8, 2.8, t: newSetting.intensity.value)
                    vf.scale = SIMD3<Float>(vfScale, vfScale, vfScale)
                }
            }

            // 網膜色素変性症：表示/非表示 + intensity に応じたスケール更新
            // intensity=0（軽度）: スケール 1.0（やや広めの視野残存）
            // intensity=1（重度）: スケール 3.2（重度のトンネル視野）
            if let rp = retinitisEntity {
                rp.isEnabled = isRetinitis
                if isRetinitis {
                    let rpScale = mix(1.0, 3.2, t: newSetting.intensity.value)
                    rp.scale = SIMD3<Float>(rpScale, rpScale, rpScale)
                }
            }

            // 飛蚊症（ゴマ状）の表示・非表示と intensity によるスケール更新
            // intensity に応じてスケールを変化させる：
            //   軽度（0.0）: scale 0.5 → 小さく薄く見える
            //   重度（1.0）: scale 1.8 → 大きくはっきり見える
            if isFloaters {
                let floaterScale = mix(0.5, 1.8, t: newSetting.intensity.value)
                let entities = floaterEntitiesByType.first ?? []
                for e in entities {
                    e.isEnabled = true
                    e.scale = SIMD3<Float>(floaterScale, floaterScale, floaterScale)
                }
                floaterEntities = entities
            } else {
                // 飛蚊症 Entity を非表示
                for entities in floaterEntitiesByType {
                    for e in entities { e.isEnabled = false }
                }
                floaterEntities = []
            }

            // ドームの CI フィルター再適用（中心暗点・飛蚊症はドームに何もしない）
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
    // 1. 症状が「なし」なら元テクスチャをそのまま左右に使う
    // 2. 症状あり → appModel.sourceStereoImages の左右 CGImage に同じフィルターをかける
    // 3. フィルター済み左右 CGImage から TextureResource を生成
    // 4. ShaderGraphMaterial（StereoscopicMaterial）に設定してドームに適用
    //    → CameraIndexSwitch ノードが左目/右目に別テクスチャを表示し立体感を維持
    //
    // 【なぜ TextureResource → CGImage 変換を廃止したか】
    // TextureResource.copy(to: MTLTexture) → getBytes() のパスは
    // visionOS 実機で正常に動作しないケースがあるため、
    // ContentView で StereoImagePair を生成した時点の CGImage を
    // AppModel 経由で直接受け取る方式に変更した。
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

        // タスクキャンセルチェック（スライダー連打でキャンセルされた場合は何もしない）
        if Task.isCancelled { return }

        // 症状なし → 元テクスチャをそのまま適用（フィルター不要）
        if setting.type == .none {
            await applyStereoMaterial(left: textures.left, right: textures.right, to: entity)
            print("✅ マテリアル更新: 症状なし")
            return
        }

        // フィルターをかけるための元 CGImage を取得
        // AppModel に保存された元画像を直接使う（GPU → CPU 変換コストなし）
        guard let stereoImages = appModel.sourceStereoImages else {
            // CGImage が未設定の場合は元テクスチャをそのまま使う
            print("⚠️ sourceStereoImages 未設定、元テクスチャを使用")
            await applyStereoMaterial(left: textures.left, right: textures.right, to: entity)
            return
        }

        // 左目・右目それぞれの CIImage を生成
        let leftCI  = CIImage(cgImage: stereoImages.left)
        let rightCI = CIImage(cgImage: stereoImages.right)

        // 左目・右目に同じフィルターをかける
        // （症状は両眼に同じように現れる）
        let filteredLeft: CIImage
        let filteredRight: CIImage

        switch setting.type {
        case .none:
            // ここには来ない（上でreturnしている）
            filteredLeft  = leftCI
            filteredRight = rightCI

        case .visualField:
            // Entity オーバーレイ方式で実装するため、ドームには何もしない
            filteredLeft  = leftCI
            filteredRight = rightCI

        case .colorBlind:
            filteredLeft  = applyColorBlindFilter(to: leftCI,  type: setting.colorBlindType, intensity: setting.intensity.value)
            filteredRight = applyColorBlindFilter(to: rightCI, type: setting.colorBlindType, intensity: setting.intensity.value)

        case .cataract:
            filteredLeft  = applyCataractFilter(to: leftCI,  intensity: setting.intensity.value)
            filteredRight = applyCataractFilter(to: rightCI, intensity: setting.intensity.value)

        case .retinitispigmentosa:
            // Entity オーバーレイ方式で実装するため、ドームには何もしない
            filteredLeft  = leftCI
            filteredRight = rightCI

        case .presbyopia:
            filteredLeft  = applyPresbyopiaFilter(to: leftCI,  intensity: setting.intensity.value)
            filteredRight = applyPresbyopiaFilter(to: rightCI, intensity: setting.intensity.value)

        case .astigmatism:
            filteredLeft  = applyAstigmatismFilter(to: leftCI,  intensity: setting.intensity.value)
            filteredRight = applyAstigmatismFilter(to: rightCI, intensity: setting.intensity.value)

        case .scotoma:
            // Entity オーバーレイ方式で実装するため、ドームには何もしない
            filteredLeft  = leftCI
            filteredRight = rightCI

        case .floaters:
            // Entity オーバーレイ方式で実装するため、ドームには何もしない
            filteredLeft  = leftCI
            filteredRight = rightCI
        }

        // キャンセルチェック（重い処理の後）
        if Task.isCancelled { return }

        // 左目：CIImage → CGImage → TextureResource
        guard let leftCGImage = ciContext.createCGImage(filteredLeft, from: filteredLeft.extent) else {
            print("⚠️ CIContext.createCGImage（左目）失敗、元テクスチャを使用")
            await applyStereoMaterial(left: textures.left, right: textures.right, to: entity)
            return
        }

        // 右目：CIImage → CGImage → TextureResource
        guard let rightCGImage = ciContext.createCGImage(filteredRight, from: filteredRight.extent) else {
            print("⚠️ CIContext.createCGImage（右目）失敗、元テクスチャを使用")
            await applyStereoMaterial(left: textures.left, right: textures.right, to: entity)
            return
        }

        if Task.isCancelled { return }

        do {
            let leftTexture = try await TextureResource(
                image: leftCGImage,
                withName: nil,
                options: .init(semantic: .color)
            )
            let rightTexture = try await TextureResource(
                image: rightCGImage,
                withName: nil,
                options: .init(semantic: .color)
            )
            await applyStereoMaterial(left: leftTexture, right: rightTexture, to: entity)
            print("✅ マテリアル更新: mode=\(setting.type.rawValue), intensity=\(setting.intensity.value)")
        } catch {
            print("⚠️ TextureResource 生成失敗: \(error)")
            await applyStereoMaterial(left: textures.left, right: textures.right, to: entity)
        }
    }

    // ------------------------------------------------------------------
    // ShaderGraphMaterial（StereoscopicMaterial）に左右テクスチャを設定して
    // エンティティに適用するヘルパー
    //
    // 【立体視の仕組み】
    // RealityKitContent バンドルからコンパイル済みの StereoscopicMaterial を読み込み、
    // LeftTexture / RightTexture パラメータに左右テクスチャをセットする。
    // マテリアル内の CameraIndexSwitch（ND_realitykit_geometry_switch_cameraindex_color3）
    // ノードが左目レンダリング時は LeftTexture、右目レンダリング時は RightTexture を
    // 自動的に選択するため、両眼に別の画像が表示されて立体感が生まれる。
    //
    // 【ShaderGraphMaterial ロードに失敗した場合のフォールバック】
    // UnlitMaterial（左テクスチャのみ）で表示する。
    // 立体感は失われるが表示は維持される。
    // ------------------------------------------------------------------
    @MainActor
    private func applyStereoMaterial(
        left: TextureResource,
        right: TextureResource,
        to entity: ModelEntity
    ) async {
        do {
            // RealityKitContent バンドルのコンパイル済み Scene.reality から
            // ShaderGraphMaterial をロードする
            //
            // 【ロード方法の解説】
            // ShaderGraphMaterial(named:from:in:) の各引数：
            //   named: Scene.usda 内のマテリアル prim フルパス
            //         StereoscopicMaterial は Scene.usda の /Root/StereoscopicMaterial に
            //         インライン参照されており、その中の Material prim パスが
            //         /Root/StereoscopicMaterial/StereoscopicMaterial になる
            //   from:  .rkassets 内の USDA ファイル名（拡張子なし）
            //   in:    RealityKitContent パッケージのバンドル
            //         コンパイル済み .reality ファイルを含むため
            //         ND_RealityKitTexture2D / ND_realitykit_geometry_switch_cameraindex
            //         などの RealityKit 固有ノードが正しく解決される
            var material = try await ShaderGraphMaterial(
                named: "/Root/StereoscopicMaterial/StereoscopicMaterial",
                from: "Scene",
                in: realityKitContentBundle
            )

            // 左目テクスチャをセット
            try material.setParameter(name: "LeftTexture",  value: .textureResource(left))
            // 右目テクスチャをセット
            try material.setParameter(name: "RightTexture", value: .textureResource(right))

            // 内側から見えるよう両面描画（ドームの内面に貼るため）
            material.faceCulling = .none

            entity.model?.materials = [material]
        } catch {
            // ShaderGraphMaterial ロード失敗時は UnlitMaterial（単眼）にフォールバック
            print("⚠️ ShaderGraphMaterial ロード失敗、UnlitMaterial で表示: \(error)")
            var fallback = UnlitMaterial()
            fallback.color = .init(texture: .init(left))
            fallback.faceCulling = .none
            entity.model?.materials = [fallback]
        }
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
    // ヘッドの向きを毎フレーム取得し、中心暗点・飛蚊症の
    // Entity の位置を球面上でリアルタイム更新する。
    //
    // 【Entity 方式の利点】
    // CI フィルター方式は毎フレームのテクスチャ再生成（GPU → CPU → テクスチャ）が
    // 必要で実質リアルタイム追従不可能だった。
    // Entity 方式は position の更新だけなので 60fps で追従できる。
    //
    // 【スムージング（lerp α = 0.15）】
    // 生の視線をそのまま使うと Entity が震えて見える。
    // 前フレームの forward ベクトルと lerp でスムージングする。
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

        // スムージング用の前フレーム forward ベクトル
        var smoothedForward = SIMD3<Float>(0, 0, -1)  // 初期値：正面

        // 飛蚊症用：さらに遅いスムージング
        // 実際の飛蚊症は硝子体の慣性で視線より遅れて動く。
        // α=0.04 にすることで約0.5秒遅れて追従する。
        var floatersForward = SIMD3<Float>(0, 0, -1)

        // 毎フレーム（約 60fps）ヘッドの向きを取得して Entity 位置を更新
        while !Task.isCancelled {
            if let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
                let matrix = anchor.originFromAnchorTransform

                // ヘッドの前方ベクトル（-Z 軸）を抽出
                let rawForward = SIMD3<Float>(
                    -matrix.columns.2.x,
                    -matrix.columns.2.y,
                    -matrix.columns.2.z
                )

                // 中心暗点用スムージング（α = 0.15）
                smoothedForward = smoothedForward + (rawForward - smoothedForward) * 0.15
                let len1 = simd_length(smoothedForward)
                if len1 > 0.001 { smoothedForward = smoothedForward / len1 }

                // 飛蚊症用スムージング（α = 0.04：ゆっくり追従して慣性感を出す）
                floatersForward = floatersForward + (rawForward - floatersForward) * 0.04
                let len2 = simd_length(floatersForward)
                if len2 > 0.001 { floatersForward = floatersForward / len2 }

                // ヘッドの位置（ワールド座標）
                // Vision Pro では原点はフロアレベル付近、ヘッドは約1.6m上にある。
                // Entity をワールド原点基準で配置すると視線からずれるため、
                // ヘッドの実際の位置を基準にして forward 方向に配置する。
                let headPos = SIMD3<Float>(matrix.columns.3.x,
                                          matrix.columns.3.y,
                                          matrix.columns.3.z)

                // ヘッドの right/up ベクトル（飛蚊症オフセット計算用）
                let right = SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
                let up    = SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)

                // 中心暗点 Entity の位置更新
                // ヘッド位置 + smoothedForward 方向の overlayDistance に配置してから
                // look(at: headPos) でヘッド位置を向かせる（ビルボード的動作）
                // generatePlane(width:height:) の法線は +Z なので
                // look(at:from:relativeTo:) で -Z をヘッド方向に向けることで正面を向く
                if let scotoma = scotomaEntity, scotoma.isEnabled {
                    let scotomaPos = headPos + smoothedForward * overlayDistance
                    scotoma.position = scotomaPos
                    scotoma.look(at: headPos, from: scotomaPos, relativeTo: nil)
                }

                // 視野狭窄 Entity の位置更新（中心暗点と同じスムージング α=0.15）
                // ドーナツ状リングが視線中心に追従することで
                // 「周辺は暗いが視線の先は明るい」緑内障の特徴を正確に表現
                if let vf = visualFieldEntity, vf.isEnabled {
                    let vfPos = headPos + smoothedForward * overlayDistance
                    vf.position = vfPos
                    vf.look(at: headPos, from: vfPos, relativeTo: nil)
                }

                // 網膜色素変性症 Entity の位置更新（同 α=0.15）
                // 視野狭窄より暗く急峻な境界のリングで「壁」感を表現
                if let rp = retinitisEntity, rp.isEnabled {
                    let rpPos = headPos + smoothedForward * overlayDistance
                    rp.position = rpPos
                    rp.look(at: headPos, from: rpPos, relativeTo: nil)
                }

                // 飛蚊症 Entity の位置更新（遅延追従）
                // ヘッドの right/up を使って視野内に分散配置する
                if !floaterEntities.isEmpty && floaterEntities[0].isEnabled {
                    for entity in floaterEntities {
                        if let offset = entity.components[FloaterOffsetComponent.self] {
                            let worldPos = headPos
                                + floatersForward * overlayDistance
                                + right * offset.horizontal
                                + up    * offset.vertical
                            entity.position = worldPos
                        }
                    }
                }
            }

            // 約 60fps でポーリング（16ms）
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    // ------------------------------------------------------------------
    // 飛蚊症 Entity のオフセット情報を保持するカスタムコンポーネント
    //
    // RealityKit の Component プロトコルを実装することで
    // Entity にカスタムデータを添付できる。
    // React Native の props に相当するイメージ。
    // ------------------------------------------------------------------
    struct FloaterOffsetComponent: Component {
        var horizontal: Float  // カメラ座標系での水平オフセット（メートル）
        var vertical: Float    // カメラ座標系での垂直オフセット（メートル）
    }

    // ------------------------------------------------------------------
    // 中心暗点 Entity を生成する
    //
    // 【方式】
    // generatePlane(width:height:) を使う。この平面は XY 平面で法線が +Z 軸。
    // startARKitTracking 内で毎フレーム entity.look(at: headPos, ...) を呼ぶことで
    // 平面が常にユーザーの方向を向く（ビルボード的動作）。
    //
    // テクスチャ：中心が黒不透明、外縁が透明のグラデーション円。
    // 実際の中心暗点は境界がはっきりしておらず、中心から外側にフェードする。
    // ------------------------------------------------------------------
    @MainActor
    private func makeScotomaEntity() -> ModelEntity {
        let size = 512
        guard let ctx = CGContext(
            data: nil,
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return ModelEntity() }

        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

        // 放射状グラデーション：中心が完全な黒 → 外縁が透明
        // 中心の広い範囲を高不透明度で塗り、外縁だけをぼかす
        // これにより「視野が欠けている」感が明確に伝わる
        let center = CGPoint(x: size / 2, y: size / 2)
        let radius = CGFloat(size) / 2.0
        let colors: [CGColor] = [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.98),  // 中心：完全に近い黒
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.95),  // 中心付近：ほぼ黒を広く保つ
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.60),  // グラデーション開始
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.0),   // 外縁：完全透明
        ]
        let locations: [CGFloat] = [0.0, 0.50, 0.78, 1.0]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors as CFArray, locations: locations) {
            ctx.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: radius,
                options: []
            )
        }

        guard let cgImage = ctx.makeImage() else { return ModelEntity() }

        // generatePlane(width:height:) → 法線が +Z 軸（XY平面）
        // overlayDistance=1.5m に合わせて 0.6m × 0.6m のベースサイズ
        // （3.0m先の1.2m平面と同じ視野角になる）
        // faceCulling = .none で裏からも見える
        let mesh = MeshResource.generatePlane(width: 0.6, height: 0.6)
        var material = UnlitMaterial()
        material.faceCulling = .none

        do {
            let texture = try TextureResource(
                image: cgImage,
                withName: nil,
                options: .init(semantic: .color)
            )
            material.color = .init(texture: .init(texture))
            material.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        } catch {
            print("⚠️ 中心暗点テクスチャ生成失敗: \(error)")
        }

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "ScotomaOverlay"
        entity.scale = SIMD3<Float>(1.0, 1.0, 1.0)
        return entity
    }

    // ------------------------------------------------------------------
    // 視野狭窄オーバーレイ Entity を生成する
    //
    // 【緑内障などの視野狭窄の特徴】
    // ・周辺視野が失われ、中心部だけが見える
    // ・境界はなだらかなグラデーション
    //
    // 【実装方針】
    // 中心が透明（穴）で周辺が暗い「ドーナツ状」のテクスチャを持つ平面 Entity。
    // 中心の透明部分がそのまま「見える視野」に対応する。
    //
    // テクスチャ：中心（半径 35%）が完全透明、そこから外側に向けて黒くなるグラデーション。
    // 中心暗点と逆のグラデーション方向になる。
    // ------------------------------------------------------------------
    @MainActor
    private func makeVisualFieldEntity() -> ModelEntity {
        let size = 512
        guard let ctx = CGContext(
            data: nil,
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return ModelEntity() }

        // 全体を半透明の黒で塗りつぶす（周辺の暗い部分）
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.88))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // 中心に向かって透明になる放射状グラデーションを重ねる
        // これにより「中心が透明（視野あり）・周辺が黒（視野なし）」のドーナツ形状になる
        let center = CGPoint(x: size / 2, y: size / 2)
        let radius = CGFloat(size) / 2.0
        let colors: [CGColor] = [
            CGColor(red: 0, green: 0, blue: 0, alpha: 1.0),  // 完全な黒（完全に上書き）
            CGColor(red: 0, green: 0, blue: 0, alpha: 1.0),  // 境界付近まで黒を維持
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.5),  // グラデーション開始
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.0),  // 中心：完全透明（視野あり）
        ]
        // 外側（1.0）から内側（0.0）に向かうグラデーション
        // locations は内側基準（0=中心, 1=外縁）
        let locations: [CGFloat] = [0.0, 0.30, 0.60, 1.0]

        // destination-out でくり抜く（透明の穴を開ける）
        ctx.setBlendMode(.destinationOut)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations
        ) {
            ctx.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: radius,
                options: []
            )
        }

        guard let cgImage = ctx.makeImage() else { return ModelEntity() }

        // overlayDistance=1.5m に合わせた大きめサイズ（3.0m × 3.0m ベース）
        // 視野全体を覆えるよう中心暗点より大きくする
        // scale でサイズを調整するため、ベースは大きめにしておく
        let mesh = MeshResource.generatePlane(width: 3.0, height: 3.0)
        var material = UnlitMaterial()
        material.faceCulling = .none

        do {
            let texture = try TextureResource(
                image: cgImage,
                withName: nil,
                options: .init(semantic: .color)
            )
            material.color = .init(texture: .init(texture))
            material.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        } catch {
            print("⚠️ 視野狭窄テクスチャ生成失敗: \(error)")
        }

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "VisualFieldOverlay"
        return entity
    }

    // ------------------------------------------------------------------
    // 網膜色素変性症オーバーレイ Entity を生成する
    //
    // 【視野狭窄との違い】
    // ・より強い暗化（周辺が真っ黒）
    // ・より急峻な境界（「壁」的な見え方）
    // ・中心の透明領域がより小さい（重度のトンネル視野感）
    //
    // 【実装方針】
    // 視野狭窄と同じドーナツ構造だが、
    // グラデーション幅を狭くして境界を急峻にする。
    // ------------------------------------------------------------------
    @MainActor
    private func makeRetinitisEntity() -> ModelEntity {
        let size = 512
        guard let ctx = CGContext(
            data: nil,
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return ModelEntity() }

        // 視野狭窄より不透明度を高くする（より暗い周辺）
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.96))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let center = CGPoint(x: size / 2, y: size / 2)
        let radius = CGFloat(size) / 2.0

        // 視野狭窄よりグラデーション幅を狭く（0.15 → 急峻な境界）
        // これにより緑内障の「ぼんやりした境界」ではなく
        // 網膜色素変性症の「壁のような境界」を表現する
        let colors: [CGColor] = [
            CGColor(red: 0, green: 0, blue: 0, alpha: 1.0),  // 外周：完全な黒
            CGColor(red: 0, green: 0, blue: 0, alpha: 1.0),  // 黒を広く維持
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.3),  // 急なグラデーション開始
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.0),  // 中心：完全透明
        ]
        // 視野狭窄（0.60）より狭いグラデーション幅（0.72）で急峻な境界を作る
        let locations: [CGFloat] = [0.0, 0.40, 0.72, 1.0]

        ctx.setBlendMode(.destinationOut)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations
        ) {
            ctx.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: radius,
                options: []
            )
        }

        guard let cgImage = ctx.makeImage() else { return ModelEntity() }

        let mesh = MeshResource.generatePlane(width: 3.0, height: 3.0)
        var material = UnlitMaterial()
        material.faceCulling = .none

        do {
            let texture = try TextureResource(
                image: cgImage,
                withName: nil,
                options: .init(semantic: .color)
            )
            material.color = .init(texture: .init(texture))
            material.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        } catch {
            print("⚠️ 網膜色素変性症テクスチャ生成失敗: \(error)")
        }

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "RetinitisOverlay"
        return entity
    }

    // ------------------------------------------------------------------
    // 飛蚊症 Entity 群を生成する（ゴマ状のみ）
    //
    // 小さな半透明の暗い球体を7個配置する。
    // 球体は向き不問で、視野内にランダムに分散する。
    //
    // 各飛蚊の定義：(水平オフセットm, 垂直オフセットm, 半径m, 不透明度)
    // オフセットはヘッドの right/up ベクトル方向の距離（メートル）
    // overlayDistance = 1.5m 基準のオフセット・サイズ
    // ------------------------------------------------------------------
    @MainActor
    private func makeFloaterEntities() -> [ModelEntity] {
        // (水平オフセット m, 垂直オフセット m, 半径 m, 不透明度)
        // ゴマ状：小さな球が7個、視野内に分散
        let defs: [(Float, Float, Float, Float)] = [
            ( 0.06,  0.05, 0.015, 0.52),
            (-0.10,  0.03, 0.013, 0.44),
            ( 0.14, -0.04, 0.014, 0.48),
            (-0.03,  0.11, 0.011, 0.40),
            ( 0.08, -0.09, 0.013, 0.46),
            (-0.16,  0.08, 0.011, 0.42),
            ( 0.11,  0.14, 0.010, 0.38),
        ]

        var entities: [ModelEntity] = []
        for (hOffset, vOffset, radius, opacity) in defs {
            let mesh = MeshResource.generateSphere(radius: radius)
            var material = UnlitMaterial(color: .init(white: 0.05, alpha: CGFloat(opacity)))
            material.faceCulling = .none
            material.blending = .transparent(opacity: .init(floatLiteral: Float(opacity)))

            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.name = "FloaterOverlay"
            entity.components.set(FloaterOffsetComponent(horizontal: hOffset, vertical: vOffset))
            entities.append(entity)
        }
        return entities
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
