# 次セッション引き継ぎドキュメント

最終更新: 2026-03-08（App Store リリース済み）

---

## 現在の状態

全フェーズ**完了**。アプリは実機（Apple Vision Pro）で正常に動作し、**App Store でリリース済み**。

- 空間写真の立体視（左右目の分離・CameraIndexSwitch による表示）が正しく動作
- 8症状すべて実装済み（うち4症状はヘッドトラッキング連動の Entity オーバーレイ方式）
- 日英ローカライゼーション対応済み
- **App Store リリース済み**: https://apps.apple.com/jp/app/id6760091243

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

**App Store リリース済み**（https://apps.apple.com/jp/app/id6760091243）

現時点で追加予定の機能は特になし。必要に応じてアップデートを検討。

---

## 実装済みの全症状

| 症状 | 手法 |
|---|---|
| 視野狭窄（緑内障） | ARKit WorldTracking + Entity オーバーレイ（ドーナツ状、α=0.15 スムージング） |
| 色覚異常（3タイプ） | Brettel 1997 行列変換（CIColorMatrix） |
| 白内障 | CIGaussianBlur + Bloom（輝度抽出→ブラー→加算）+ 黄変 |
| 網膜色素変性症 | ARKit WorldTracking + Entity オーバーレイ（急峻な境界・α=0.15 スムージング） |
| 老眼 | CIGaussianBlur + コントラスト調整 |
| 乱視 | CIMotionBlur（30度）+ 輝度マスク |
| 中心暗点 | ARKit WorldTracking + Entity オーバーレイ（α=0.15 スムージング） |
| 飛蚊症 | ARKit WorldTracking + Entity オーバーレイ（α=0.04 遅延追従） |

### Entity オーバーレイ方式の実装アーキテクチャ

CI フィルター方式（毎フレームのテクスチャ再生成）ではリアルタイム追従が不可能なため、
視野狭窄・網膜色素変性症・中心暗点・飛蚊症の4症状に **RealityKit Entity オーバーレイ方式**を採用。

**ドーナツ状テクスチャ生成（視野狭窄・網膜色素変性症）:**
- `CGContext` で全体を黒（alpha 0.88〜0.96）で塗る
- `destinationOut` ブレンドモードで中心を放射グラデーションで透明にくり抜く
- 視野狭窄: `locations = [0.0, 0.30, 0.60, 1.0]`（幅広なだらかグラデーション）
- 網膜色素変性症: `locations = [0.0, 0.40, 0.72, 1.0]`（急峻な「壁」感、α=0.96）

```swift
// ARKit WorldTrackingProvider でヘッドの向きを 60fps で取得
let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
let matrix = anchor.originFromAnchorTransform

// ヘッド前方ベクトル（-Z 軸）
let rawForward = SIMD3<Float>(-matrix.columns.2.x, -matrix.columns.2.y, -matrix.columns.2.z)

// 視野狭窄・網膜色素変性症・中心暗点用スムージング（α=0.15）
smoothedForward = smoothedForward + (rawForward - smoothedForward) * 0.15

// 飛蚊症用スムージング（α=0.04：硝子体の慣性感）
floatersForward = floatersForward + (rawForward - floatersForward) * 0.04

// Entity 配置：ヘッド位置 + forward * 1.5m
let overlayPos = headPos + smoothedForward * overlayDistance  // overlayDistance = 1.5
visualFieldEntity?.position = overlayPos
visualFieldEntity?.look(at: headPos, from: overlayPos, relativeTo: nil)
retinitisEntity?.position = overlayPos
retinitisEntity?.look(at: headPos, from: overlayPos, relativeTo: nil)
scotomaEntity?.position = overlayPos
scotomaEntity?.look(at: headPos, from: overlayPos, relativeTo: nil)
```

飛蚊症は `FloaterOffsetComponent`（horizontal/vertical オフセット）を各球体 Entity に添付し、
ヘッドの `right`/`up` ベクトルで視野内に分散配置する。

**視野狭窄・網膜色素変性症の scale 制御（ImmersiveView.swift の onChange）:**
```swift
// 視野狭窄: scale 0.8〜2.8（強度に応じて周辺の暗い領域が広がる）
let vfScale = mix(0.8, 2.8, t: intensity)
visualFieldEntity.scale = SIMD3<Float>(vfScale, vfScale, vfScale)

// 網膜色素変性症: scale 1.0〜3.2（より強い「視野の壁」）
let rpScale = mix(1.0, 3.2, t: intensity)
retinitisEntity.scale = SIMD3<Float>(rpScale, rpScale, rpScale)
```

### ヘッドトラッキング化の採否判断

「頭を動かしたときに見え方が変わる症状か」が判断基準。

| 症状 | 採用 | 理由 |
|---|---|---|
| 視野狭窄 | ✅ Entity オーバーレイ | 頭を向けた方向の周辺が暗くなる → 追従すると自然 |
| 網膜色素変性症 | ✅ Entity オーバーレイ | 同上 |
| 中心暗点 | ✅ Entity オーバーレイ | 視線の中心が欠ける → 追従必須 |
| 飛蚊症 | ✅ Entity オーバーレイ | 硝子体の浮遊物 → 頭の動きに対して慣性がある |
| 色覚異常 | ❌ Core Image のまま | 色の変換は全視野に均一。追従させる「中心」がない |
| 白内障 | ❌ Core Image のまま | 水晶体の問題。光散乱は全視野に均一 |
| 老眼 | ❌ Core Image のまま | 近距離のピントの問題。方向と無関係 |
| 乱視 | ❌ Core Image のまま | 角膜・水晶体のゆがみは全視野に均一 |

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
