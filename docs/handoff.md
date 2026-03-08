# 次セッション引き継ぎドキュメント

最終更新: 2026-03-08

---

## 現在の状態

フェーズ1・フェーズ2（中心暗点・飛蚊症）**完了**。アプリは実機（Apple Vision Pro）で正常に動作している。

- 空間写真の立体視（左右目の分離・CameraIndexSwitch による表示）が正しく動作
- 8症状すべて実装済み（うち2症状はヘッドトラッキング連動の Entity オーバーレイ方式）
- 日英ローカライゼーション対応済み
- **App Store 審査提出済み・審査待ち**

---

## 解決済みの重要な問題（次セッションで再発させないこと）

### 1. 空間写真の取得：PHPickerConfiguration の選択

**問題**: `PHPickerConfiguration()` を使うと NSItemProvider 経由で単一フレームに変換された HEIC（約536KB）しか取得できず、左目フレームしか取り出せない。

**解決**: `PHPickerConfiguration(photoLibrary: .shared())` を使い、`result.assetIdentifier` → `PHAssetResourceManager.requestData` で完全な HEIC バイナリを取得する。

```swift
// ContentView.swift の SpatialPhotoPicker
var config = PHPickerConfiguration(photoLibrary: .shared())
// → result.assetIdentifier → loadViaAssetResource()
```

### 2. 空間写真の左右フレーム抽出：CGImageSource API の正しい使い方

**問題**: `CGImageSourceCopyPropertiesAtIndex`（インデックスごと）で `kCGImagePropertyGroups` を探しても nil になる。

**解決**: `CGImageSourceCopyProperties`（ソース全体のプロパティ、インデックスなし）を使う。

```swift
// SpatialPhotoLoader.swift の extractStereoImages
let sourceProps = CGImageSourceCopyProperties(imageSource, nil) as? [CFString: Any]
let groups = sourceProps[kCGImagePropertyGroups] as? [[CFString: Any]]
let group = groups.first(where: {
    ($0[kCGImagePropertyGroupType] as? String) == (kCGImagePropertyGroupTypeStereoPair as String)
})
let leftIndex  = group[kCGImagePropertyGroupImageIndexLeft]  as? Int  // 0
let rightIndex = group[kCGImagePropertyGroupImageIndexRight] as? Int  // 1
```

Vision Pro 撮影の空間写真：
- compatible brand `MiHB`（Apple 空間写真のマーカー）
- `CGImageSourceGetCount` = 2（左目・右目）
- index 0 = 左目 2560x2560、index 1 = 右目 2560x2560

### 3. ShaderGraph マテリアルのロード先

**問題**: `.main` バンドルではなく `realityKitContentBundle` からロードしないと `invalidTypeFound` エラーになる。

**解決**: `ImmersiveView.swift` で以下のようにロードする。

```swift
// ImmersiveView.swift
let material = try await ShaderGraphMaterial(
    named: "/Root/StereoscopicMaterial",
    from: "Materials/StereoscopicMaterial",
    in: realityKitContentBundle   // ← ここが重要
)
```

### 4. UV V軸の反転

**問題**: ドームメッシュに投影すると画像が上下逆になる。

**解決**: `DomeMesh.swift` の UV 生成時に V 軸を反転する。

```swift
// DomeMesh.swift
uvs.append(SIMD2<Float>(ht, 1.0 - vt))  // 1.0 - vt で上下反転
```

---

## 次に実装すべきこと

### 現状

**App Store 審査提出済み・審査待ち**
- 審査が通り次第リリース
- リジェクトされた場合は `docs/app-store-metadata.md` を参照して対応する

---

## 実装済みの全症状

| 症状 | 手法 |
|---|---|
| 視野狭窄（緑内障） | ARKit WorldTracking + Entity オーバーレイ（外周暗化テクスチャ・α=0.15 スムージング） |
| 色覚異常（3タイプ） | Brettel 1997 行列変換（CIColorMatrix） |
| 白内障 | CIGaussianBlur + Bloom（輝度抽出→ブラー→加算）+ 黄変 |
| 網膜色素変性症 | ARKit WorldTracking + Entity オーバーレイ（外周黒・中心透明テクスチャ・α=0.15 スムージング） |
| 老眼 | CIGaussianBlur + コントラスト調整 |
| 乱視 | CIMotionBlur（30度）+ 輝度マスク |
| 中心暗点 | ARKit WorldTracking + Entity オーバーレイ（α=0.15 スムージング） |
| 飛蚊症 | ARKit WorldTracking + Entity オーバーレイ（α=0.04 遅延追従） |

### Entity オーバーレイ方式（4症状共通アーキテクチャ）

CI フィルター方式（毎フレームのテクスチャ再生成）ではリアルタイム追従が不可能なため、
視野狭窄・網膜色素変性症・中心暗点・飛蚊症の4症状すべてで **RealityKit Entity オーバーレイ方式**を採用。

**基本原則：**
- 6m×6m の平面 `ModelEntity` を生成（`overlayDistance=1.5m` で ±60度をカバーするため）
- テクスチャで「透明な部分＝見える範囲、不透明な部分＝症状による視野制限」を表現
- `CGContext.clear()` で初期化してから `drawRadialGradient` を描画（`fill()` では透明にならない）
- Entity の向きは `entity.orientation = headOrientation`（`look(at:)` は平面が傾くためNG）

```swift
// ARKit WorldTrackingProvider でヘッドの向きを 60fps で取得
let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
let matrix = anchor.originFromAnchorTransform

// ヘッドの向きをクォータニオンとして抽出（向き設定に使用）
let rotMatrix = simd_float3x3(
    SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
    SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
    SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
)
let headOrientation = simd_quatf(rotMatrix)

// ヘッド前方ベクトル（-Z 軸）
let rawForward = SIMD3<Float>(-matrix.columns.2.x, -matrix.columns.2.y, -matrix.columns.2.z)

// 中心暗点・視野狭窄・網膜色素変性症用スムージング（α=0.15）
smoothedForward = smoothedForward + (rawForward - smoothedForward) * 0.15

// 飛蚊症用スムージング（α=0.04：硝子体の慣性感）
floatersForward = floatersForward + (rawForward - floatersForward) * 0.04

// Entity 配置：ヘッド位置 + forward * 1.5m
let pos = headPos + smoothedForward * overlayDistance  // overlayDistance = 1.5
entity.position = pos
entity.orientation = headOrientation  // look(at:) ではなく orientation を直接設定
```

**症状別テクスチャ構造：**
- 視野狭窄：中心透明 → 外周ほど黒アルファが上がるラジアルグラデーション（周辺視野の暗化）
- 網膜色素変性症：中心だけ透明（小さい円）→ 外周は黒（周辺視野ほぼゼロ）
- 中心暗点：中心が黒不透明 → 外縁が透明のグラデーション（中心部の暗点）

**intensity 変化時の処理：**
テクスチャを差し替え方式（`updateVisualFieldTexture()` / `updateRetinitisTexture()` を再呼び出し）。
板サイズは 6m×6m 固定（スケール変更では透明穴と板が同比率で変化するため視野角が変わらない）。

飛蚊症は `FloaterOffsetComponent`（horizontal/vertical オフセット）を各球体 Entity に添付し、
ヘッドの `right`/`up` ベクトルで視野内に分散配置する。

---

## ファイル構成（現在）

```
ThroughMySpace/
├── CLAUDE.md                            # AI への指示（本リポジトリ）
├── README.md                            # プロジェクト概要
├── LICENSE
├── DomeMesh.swift                       # ドームメッシュ生成（プロジェクトルートに配置）
├── ThroughMySpace/                      # アプリ本体ソース
│   ├── AppModel.swift                   # グローバル状態（@Observable）
│   ├── ContentView.swift                # 起動画面・SpatialPhotoPicker
│   ├── ImmersiveView.swift              # Full Immersion Space 体験本体
│   ├── Models/
│   │   └── Condition.swift             # 症状データモデル・フィルターロジック
│   ├── Views/
│   │   ├── FloatingPanelView.swift      # 症状選択パネル
│   │   ├── InfoView.swift               # 症状説明カード
│   │   └── EntryNoticeView.swift        # 体験開始免責事項
│   ├── Services/
│   │   └── SpatialPhotoLoader.swift     # HEIC 読み込み・左右分離
│   └── Resources/
│       ├── Localizable.strings/en       # 英語ローカライズ
│       ├── Localizable.strings/ja       # 日本語ローカライズ
│       └── StereoscopicMaterial.usda    # （未使用・RealityKitContent 側を使用）
├── Packages/RealityKitContent/
│   └── .rkassets/Materials/
│       └── StereoscopicMaterial.usda    # 実際に使われるシェーダー
└── docs/
    ├── through-my-space-spec.md         # 仕様書
    ├── app-store-metadata.md            # App Store メタデータ
    ├── handoff.md                       # このファイル
    ├── index.html                       # GitHub Pages トップ
    ├── privacy.html                     # プライバシーポリシー
    └── support.html                     # サポートページ
```

---

## アーキテクチャの概要

### 状態管理（AppModel.swift）

React Native の Context に相当する `@Observable` クラス。

```
AppModel
├── selectedStereoTextures: StereoTextures?   // 処理済みテクスチャ（左右）
├── sourceStereoImages: StereoCGImages?        // 元画像の CGImage（フィルター再適用用）
├── currentCondition: ConditionType            // 選択中の症状
├── conditionIntensity: Float                  // 症状の強度 0.0〜1.0
├── textureVersion: Int                        // テクスチャ更新トリガー（onChange で検知）
└── immersiveSpaceState: ImmersiveSpaceState
```

### テクスチャ更新フロー

```
ContentView（写真選択）
  → SpatialPhotoLoader.loadStereoImages(from: Data)
  → sourceStereoImages に元画像を保存
  → Condition.applyFilter で Core Image フィルター適用
  → selectedStereoTextures を更新
  → textureVersion += 1
  → ImmersiveView の onChange が発火
  → domeEntity のマテリアルパラメータを更新
```

### フィルター適用（Condition.swift）

症状ごとの Core Image フィルター処理は `Condition.swift` の `applyFilter` 関数に集約されている。左右別々に同じフィルターを適用する。

---

## 注意事項

- `DomeMesh.swift` がプロジェクトルートに置かれているが、Xcode プロジェクトには含まれている（`.xcodeproj` で参照）
- `ThroughMySpace/Resources/StereoscopicMaterial.usda` は古いバージョンで現在は**使っていない**。`Packages/RealityKitContent` 側を使用
- シミュレーターでは `PHPickerConfiguration()` モード（フォールバック）になるため立体視は動作しない。実機テストが必須
- アイトラッキングは実機のみ。シミュレーターでは ARKit が使えない
