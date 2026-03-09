# CLAUDE.md

## プロジェクト概要

視覚症状（視野狭窄・色覚異常・白内障など）を、
自分の空間写真を使って体験するvisionOSアプリ。
詳細な仕様は `docs/through-my-space-spec.md` を参照。

---

## コンセプトの核心

「あなたが毎日見ているこの空間を、別の目で見てください。」

「完全再現」を謳わない。「体験のきっかけ」として謙虚に提示する。
これを常に意識して実装すること。

---

## 開発者について

- React Native (Expo) の経験はあるが、Swift / Xcode / visionOS は初めて
- Metal・シェーダーの経験もない
- コードの説明は日本語でコメントを入れること
- 難しい概念はReact Nativeと対比して説明してくれると助かる
- Metalシェーダーは特に丁寧に説明すること

---

## 実装ルール

- SwiftUI + RealityKit を使うこと
- Full Immersion Space で体験させること
- コメントは日本語で書くこと
- 1ファイルが長くなりすぎないよう適切にファイルを分割すること

---

## 最重要：空間写真の取り扱い（解決済み・要注意）

空間写真は左目用・右目用の2枚の画像が1つのファイル（HEIC）にパッケージされている。

### 写真の取得方法

`PHPickerConfiguration()` ではなく **`PHPickerConfiguration(photoLibrary: .shared())`** を使うこと。
前者は NSItemProvider 経由で単一フレームのみ返す。後者は `assetIdentifier` が取得できるため
`PHAssetResourceManager` で完全な HEIC バイナリが取得できる。

```swift
// 正しい取得方法
var config = PHPickerConfiguration(photoLibrary: .shared())
// → result.assetIdentifier → PHAsset → PHAssetResource → PHAssetResourceManager.requestData
```

### 左右フレームの抽出方法

**`kCGImagePropertyGroups` はインデックスごとのプロパティには存在しない。**
`CGImageSourceCopyProperties`（ソース全体のプロパティ）に存在する。

```swift
// 正しい方法
let sourceProps = CGImageSourceCopyProperties(imageSource, nil) as? [CFString: Any]
let groups = sourceProps[kCGImagePropertyGroups] as? [[CFString: Any]]
let group = groups.first(where: { ($0[kCGImagePropertyGroupType] as? String) == (kCGImagePropertyGroupTypeStereoPair as String) })
let leftIndex  = group[kCGImagePropertyGroupImageIndexLeft]  as? Int  // 通常 0
let rightIndex = group[kCGImagePropertyGroupImageIndexRight] as? Int  // 通常 1
// → CGImageSourceCreateImageAtIndex(imageSource, leftIndex, ...)
```

Vision Pro 撮影の空間写真（HEIC）の内部構造：
- `compatible brands: MiHB` — Apple 空間写真のマーカー
- `ster` グループ → `GroupImageIndexLeft=0`、`GroupImageIndexRight=1`
- index 0: 左目 2560x2560（25タイル合成）
- index 1: 右目 2560x2560（25タイル合成）

### 左右テクスチャの表示方法

ShaderGraph の `ND_realitykit_geometry_switch_cameraindex_color3` ノード（CameraIndexSwitch）を使う。
左目レンダリング時に `left` 入力を、右目レンダリング時に `right` 入力を自動選択する。

---

## 視覚フィルターの実装方針

### Core Image 方式（4症状）

visionOS では Metal の CustomMaterial が使用不可なため、Core Image でフィルターを適用し処理済みテクスチャをマテリアルに渡す。

- 色覚異常：`CIColorMatrix`（Brettel 1997 行列変換、3タイプ）
- 白内障：`CIGaussianBlur` + Bloom（輝度抽出 → ブラー → 加算合成）+ 黄変
- 老眼：`CIGaussianBlur` + コントラスト調整
- 乱視：`CIMotionBlur`（30度方向）+ 輝度マスク

### RealityKit Entity オーバーレイ方式（4症状）

CI フィルター方式（毎フレームのテクスチャ再生成）では 60fps のリアルタイム追従が不可能なため、
視野狭窄・網膜色素変性症・中心暗点・飛蚊症の4症状に採用。

- ARKit `WorldTrackingProvider.queryDeviceAnchor` でヘッドの向きを 60fps で取得
- 6m×6m の平面 Entity をヘッド前方 `overlayDistance=1.5m` に配置し毎フレーム `position` を更新
- **向き設定は `entity.orientation = headOrientation`（`look(at:)` は平面が傾くためNG）**
- **テクスチャ生成：`CGContext.clear()` で初期化後に `drawRadialGradient`（`fill()` では透明にならない）**
- **スムージング**：視野狭窄・網膜色素変性症・中心暗点は α=0.15、飛蚊症は α=0.04（硝子体の慣性感）で lerp
- **板サイズ 6m×6m 固定**：intensity 変化時はスケール変更ではなくテクスチャを差し替える（スケール変更では透明穴と板が同比率で変化するため視野角が変わらない）
- **飛蚊症オフセット**：`FloaterOffsetComponent` で各球体の水平・垂直オフセットを保持し `right/up` ベクトルで分散配置

---

## 免責事項（必ず実装すること）

アプリ内の以下の箇所に免責事項を表示すること。
- 起動時
- 各症状の説明画面

```
このアプリが提供する体験は近似的なシミュレーションです。
実際の視覚症状は個人差があります。
医療診断・治療の代替として使用しないでください。
```

---

## フォルダ構成

```
ThroughMySpace/
├── ThroughMySpace/               # アプリ本体
│   ├── Models/
│   │   └── Condition.swift       # 症状データモデル
│   ├── Views/
│   │   ├── ContentView.swift     # メイン画面・写真選択（SpatialPhotoPicker含む）
│   │   ├── ImmersiveView.swift   # Full Immersion 体験本体
│   │   ├── FloatingPanelView.swift
│   │   ├── InfoView.swift
│   │   └── EntryNoticeView.swift
│   ├── Services/
│   │   └── SpatialPhotoLoader.swift  # 空間写真の読み込み・左右分離
│   ├── DomeMesh.swift            # 前方ドーム状メッシュ生成
│   └── AppModel.swift            # グローバル状態管理
├── Packages/RealityKitContent/   # Reality Composer Pro アセット
│   └── .rkassets/Materials/
│       └── StereoscopicMaterial.usda
└── docs/                         # ドキュメント
    ├── through-my-space-spec.md
    └── app-store-metadata.md
```

---

## 現在の実装状況

- [x] フェーズ1：空間写真の左右分離（立体視）
- [x] フェーズ1：PHPickerViewController + PHAssetResourceManager で完全 HEIC 取得
- [x] フェーズ1：ドームメッシュ展開・Full Immersion Space 表示
- [x] フェーズ1：フローティングパネルUI
- [x] フェーズ1：色覚異常・白内障・老眼・乱視（Core Image フィルター方式）
- [x] フェーズ1：症状説明 InfoView、体験開始免責事項 EntryNoticeView
- [x] フェーズ1：日英ローカライゼーション
- [x] フェーズ2：中心暗点（ヘッドトラッキング連動・Entity オーバーレイ方式）
- [x] フェーズ2：飛蚊症（ヘッドトラッキング連動・Entity オーバーレイ方式）
- [x] フェーズ2：視野狭窄（ヘッドトラッキング連動・Entity オーバーレイ方式に移行）
- [x] フェーズ2：網膜色素変性症（ヘッドトラッキング連動・Entity オーバーレイ方式に移行）
- [x] フェーズ2：App Store 申請（審査提出済み・審査待ち）

### フェーズ3（未着手）— 詳細は `docs/through-my-space-spec.md` を参照

**機能追加**
- [ ] 症状の重ねがけモード（複数症状の同時適用）
- [ ] 当事者の声の追加（InfoView にコメント掲載）
- [ ] 症状プリセット（「70代の一般的な見え方」等のシナリオモード）
- [ ] サンプル空間写真のバンドル（ダウンロード即体験可能に）

**UX改善**
- [ ] 症状選択UIのグリッド化（HStack → LazyVGrid）
- [ ] 症状切り替え時のフェードトランジション
- [ ] 強度スライダーのスロットル（パフォーマンス改善）
- [ ] 写真の履歴管理
- [ ] 初回オンボーディング（空間写真の撮り方チュートリアル）
- [ ] フローティングパネルのリポジション（視界外に取り残される問題）
- [ ] SpatialPhotoError のエラーメッセージローカライズ

**技術改善**
- [ ] ImmersiveView.swift の分割（800行超→Entity生成・CIフィルター・ヘッドトラッキングを分離）
- [ ] Entity オーバーレイ生成の非同期化（初期表示速度改善）

**プロダクト品質**
- [ ] アクセシビリティ対応（VoiceOver・Dynamic Type・accessibilityLabel）
- [ ] 体験の共有機能（スクリーンショット + SNSシェア）
- [ ] 匿名利用統計（展示運用向け）

### 実装済み症状一覧

| 症状 | 状態 | 手法 |
|---|---|---|
| 視野狭窄（緑内障） | ✅ 実装済み | ARKit ヘッドトラッキング + Entity オーバーレイ（外周暗化・α=0.15） |
| 色覚異常 | ✅ 実装済み | Brettel 1997 行列変換（3タイプ） |
| 白内障 | ✅ 実装済み | CIGaussianBlur + Bloom + 黄変 |
| 網膜色素変性症 | ✅ 実装済み | ARKit ヘッドトラッキング + Entity オーバーレイ（外周黒・中心透明・α=0.15） |
| 老眼 | ✅ 実装済み | CIGaussianBlur + コントラスト調整 |
| 乱視 | ✅ 実装済み | CIMotionBlur（30度）+ 輝度マスク |
| 中心暗点 | ✅ 実装済み | ARKit ヘッドトラッキング + Entity オーバーレイ（中心暗点・α=0.15） |
| 飛蚊症 | ✅ 実装済み | ARKit ヘッドトラッキング + Entity オーバーレイ（遅延追従 α=0.04） |

### 新規症状の追加候補 — 詳細は `docs/through-my-space-spec.md` を参照

| 難易度 | 症状 |
|---|---|
| 🟢 実装しやすい | 糖尿病性網膜症、夜盲症、羞明（光過敏）、コントラスト感度低下、スターガルト病 |
| 🟡 工夫が必要 | 高度近視、半盲・四分盲、角膜ジストロフィー |
| 🔴 実装困難 | 眼振（VR酔いリスク）、複視（立体視と競合）、レーバー先天性黒内障（コンセプト不適合） |

---

## App Store申請時の注意

- カテゴリ：教育 / ヘルスケア＆フィットネス
- 年齢制限：4+
- 申請説明文：「視覚症状を自分の空間で体験する教育・共感ツール」
- 免責事項をアプリ内に必ず表示すること
- 詳細は `docs/app-store-metadata.md` を参照
