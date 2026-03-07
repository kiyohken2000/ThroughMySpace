# Through My Space

**「あなたが毎日見ているこの空間を、別の目で見てください。」**

自分の空間写真を使って視覚症状を体験する visionOS アプリ。

**App Store**: https://apps.apple.com/jp/app/id6760091243

---

## 概要

視野狭窄・色覚異常などの視覚症状を、**自分が撮影した空間写真**に適用して体験できる Apple Vision Pro アプリ。

他人が用意したストック素材ではなく「自分の部屋・自分の職場」が変容することで、視覚障害の当事者への共感と理解を生む。

> このアプリが提供する体験は近似的なシミュレーションです。実際の視覚症状は個人差があります。医療診断・治療の代替として使用しないでください。

---

## 特徴

- **自分の空間で体験** — フォトライブラリの空間写真（Spatial Photo）をそのまま使用
- **Full Immersion Space** — Vision Pro の没入空間で全周囲を包む体験
- **立体感の保持** — 空間写真の左右テクスチャを ShaderGraph の CameraIndexSwitch ノードで左右目に出し分け
- **リアルタイム切り替え** — 症状・強度をフローティングパネルでその場で変更
- **日英対応** — 端末の言語設定に応じて自動切り替え

---

## 対応する視覚症状

| 症状 | 手法 | 状態 |
|---|---|---|
| 視野狭窄（緑内障） | ヘッドトラッキング + Entity オーバーレイ | ✅ 実装済み |
| 色覚異常（3タイプ） | Brettel 1997 行列変換（CIColorMatrix） | ✅ 実装済み |
| 白内障 | CIGaussianBlur + Bloom + 黄変 | ✅ 実装済み |
| 網膜色素変性症 | ヘッドトラッキング + Entity オーバーレイ | ✅ 実装済み |
| 老眼 | CIGaussianBlur + コントラスト調整 | ✅ 実装済み |
| 乱視 | CIMotionBlur（30度）+ 輝度マスク | ✅ 実装済み |
| 中心暗点 | ヘッドトラッキング + Entity オーバーレイ（α=0.15） | ✅ 実装済み |
| 飛蚊症 | ヘッドトラッキング + Entity オーバーレイ（α=0.04） | ✅ 実装済み |

---

## 動作環境

| 項目 | 要件 |
|---|---|
| デバイス | Apple Vision Pro |
| OS | visionOS 2.0 以上 |
| 開発環境 | Xcode 16 以上 |

---

## 技術スタック

- **SwiftUI** — UI
- **RealityKit + ShaderGraph** — ドームメッシュ・左右テクスチャ切り替え（CameraIndexSwitch）
- **Core Image** — 視覚フィルター（色覚異常・白内障・老眼・乱視）
- **ARKit WorldTrackingProvider** — ヘッドトラッキング（視野狭窄・網膜色素変性症・中心暗点・飛蚊症）
- **PhotosUI + PHAssetResourceManager** — 空間写真の完全HEICデータ取得

### 症状実装方式

**Core Image フィルター方式**（静的テクスチャ加工）
- 色覚異常、白内障、老眼、乱視

**RealityKit Entity オーバーレイ方式**（ヘッドトラッキング連動）
- 視野狭窄、網膜色素変性症、中心暗点、飛蚊症
- ARKit `WorldTrackingProvider.queryDeviceAnchor` でヘッド向きを 60fps 取得
- ドーナツ状テクスチャの ModelEntity をヘッド前方 1.5m に毎フレーム配置

### フィルターパイプライン

```
空間写真（HEIC）
  → PHAssetResourceManager で完全 HEIC 取得
  → CGImageSourceCopyProperties で StereoPair グループを検出
  → index 0 (Left) / index 1 (Right) を CGImageSourceCreateImageAtIndex で取得
  → Core Image フィルター適用（症状ごとの処理）
  → TextureResource（左右別々）
  → ShaderGraph StereoscopicMaterial（CameraIndexSwitch で左右を自動振り分け）
  → ドームメッシュに投影
```

### 空間写真の取り扱いで判明した重要事項

`kCGImagePropertyGroups`（左右インデックス情報）は `CGImageSourceCopyPropertiesAtIndex`（インデックスごと）には**存在しない**。
`CGImageSourceCopyProperties`（ソース全体のプロパティ）から取得し、`GroupImageIndexLeft` / `GroupImageIndexRight` でインデックス番号を得る。

```swift
// 正しい方法
let sourceProps = CGImageSourceCopyProperties(imageSource, nil)
let groups = sourceProps[kCGImagePropertyGroups]  // ← ここにある
let leftIndex  = group[kCGImagePropertyGroupImageIndexLeft]   // 通常 0
let rightIndex = group[kCGImagePropertyGroupImageIndexRight]  // 通常 1
```

---

## プロジェクト構成

```
ThroughMySpace/
├── ThroughMySpace/
│   ├── Models/
│   │   └── Condition.swift              # 症状データモデル
│   ├── Views/
│   │   ├── ContentView.swift            # メイン画面・写真選択
│   │   ├── ImmersiveView.swift          # Full Immersion 体験本体
│   │   ├── FloatingPanelView.swift      # 症状選択フローティングパネル
│   │   ├── InfoView.swift               # 症状説明（空間内に浮かぶ）
│   │   └── EntryNoticeView.swift        # 体験開始時の免責事項カード
│   ├── Services/
│   │   └── SpatialPhotoLoader.swift     # 空間写真の読み込み・左右分離
│   ├── DomeMesh.swift                   # 前方ドーム状メッシュ生成
│   └── AppModel.swift                   # グローバル状態管理
├── Packages/RealityKitContent/          # Reality Composer Pro アセット
│   └── .rkassets/Materials/
│       └── StereoscopicMaterial.usda    # 左右目切り替えシェーダー
└── docs/                                # ドキュメント・GitHub Pages
    ├── through-my-space-spec.md         # 仕様書
    └── app-store-metadata.md            # App Store メタデータ
```

---

## 想定用途

医療・福祉教育を目的とした体験・展示用アプリ。

- 医療学会・眼科学会でのデモ展示
- 企業ダイバーシティ研修
- 学校・福祉施設での教材
- Apple Store 店頭デモ

---

## License

[MIT License](LICENSE)
