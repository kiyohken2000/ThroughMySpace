# 次セッション引き継ぎドキュメント

最終更新: 2026-03-06

---

## 現在の状態

フェーズ1 **完了**。アプリは実機（Apple Vision Pro）で正常に動作している。

- 空間写真の立体視（左右目の分離・CameraIndexSwitch による表示）が正しく動作
- 8症状のうち6症状を実装済み
- 日英ローカライゼーション対応済み

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

## 次に実装すべきこと（フェーズ2）

### 優先度高

**中心暗点（Central Scotoma）**
- ARKit のアイトラッキングで視線位置（LookAt）を毎フレーム取得
- UV 座標に変換して Core Image フィルターの中心座標として渡す
- **視線スムージング必須**: `lerp(prevGaze, currentGaze, 0.15)` 程度でスムージングしないと暗点が震えて見える
- `ImmersiveView` の RealityKit `.update` クロージャでフレームごとに処理

```swift
// アイトラッキングの取得例（概要）
// ARKitSession + WorldTrackingProvider + DeviceAnchor を使う
// device anchor の向きから視線方向を計算し、ドームメッシュの UV 座標に変換
```

**飛蚊症（Floaters）**
- 中心暗点と同じくアイトラッキング連動
- 視線位置から少しオフセットした位置にランダムな半透明の影を描画
- 影の動きは視線に追従するが 0.5〜1秒の遅延を入れる

### 優先度中

**App Store 申請**
- `docs/app-store-metadata.md` にメタデータがまとまっている
- スクリーンショットの撮影が必要（visionOS 向け）
- 実機での最終動作確認
- チェックリストは `docs/app-store-metadata.md` の末尾を参照

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
