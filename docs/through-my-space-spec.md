# Through My Space - 仕様書

## アプリ概要

視野狭窄・色覚異常・白内障などの視覚症状を、
**自分の空間を撮影した空間写真を使って体験する**visionOSアプリ。

「他人が用意した風景」ではなく「自分が毎日見ている空間」が変容することで、
視覚障害の当事者への共感と理解を生む。

---

## コンセプト

「あなたが毎日見ているこの空間を、別の目で見てください。」

医療的な正確性よりも「体験のきっかけ」を重視する。
完全な再現を謳わず、「近似的な体験」として謙虚に提示する。

---

## なぜ空間写真なのか

**パススルー（現実の映像リアルタイム加工）**
→ Enterprise APIが必要 → App Store配布不可

**空間写真（撮影済みの画像に加工）**
→ 通常のAPIで可能 → 自由にシェーダーをかけられる

撮影済みの空間写真はただのデータなので、
Core Image でフィルターを適用し TextureResource として渡せる。

---

## 競合との差別化

| 既存アプリ | 弱点 | このアプリ |
|---|---|---|
| Thru My Eyes（visionOS対応） | ストック素材のみ | 自分の空間で体験 |
| iPhoneカメラ型シミュレーター | 小画面・没入感なし | Vision Proで全周没入 |
| VR型（Meta Quest等） | Appleエコシステム外 | visionOSネイティブ |

**「自分の部屋を空間写真で撮影してその目で見る」はどこにも存在しない。**

---

## ターゲット環境

- **デバイス**: Apple Vision Pro
- **OS**: visionOS 2.0以上
- **開発環境**: Xcode 16以上
- **言語**: Swift / SwiftUI / RealityKit / Core Image

---

## App Store申請情報

| 項目 | 内容 |
|---|---|
| カテゴリ | 教育 / ヘルスケア＆フィットネス |
| 年齢制限 | 4+ |
| アプリ説明 | 視覚症状を自分の空間で体験する教育・共感ツール。医療診断には使用しないこと。 |

---

## 使用フレームワーク・技術

| 用途 | 技術 |
|---|---|
| UI | SwiftUI |
| 空間表示 | RealityKit / Full Immersion Space |
| 左右目テクスチャ切り替え | ShaderGraph（CameraIndexSwitch ノード） |
| 空間写真の読み込み | PHPickerViewController + PHAssetResourceManager |
| 視覚フィルター（CI方式） | Core Image（CPU処理）— 色覚異常・白内障・老眼・乱視 |
| 視覚フィルター（Entity方式） | RealityKit ModelEntity + ARKit WorldTrackingProvider — 視野狭窄・網膜色素変性症・中心暗点・飛蚊症 |
| ドームメッシュ | RealityKit MeshResource（カスタム生成） |

---

## 対応する視覚症状

### Core Image フィルター方式（4症状）

| 症状 | 手法 |
|---|---|
| 色覚異常（3タイプ） | Brettel 1997 行列変換（CIColorMatrix） |
| 白内障 | CIGaussianBlur + Bloom（輝度抽出→ブラー→加算）+ 黄変 |
| 老眼 | CIGaussianBlur + コントラスト調整 |
| 乱視 | CIMotionBlur（30度）+ 輝度マスク |

### Entity オーバーレイ方式（4症状）

ARKit `WorldTrackingProvider.queryDeviceAnchor` でヘッドの向きを 60fps で取得し、
RealityKit Entity をヘッド前方 1.5m に配置してリアルタイム追従させる方式。
CI フィルター方式（毎フレームのテクスチャ再生成）では 60fps での追従が不可能なためこの方式を採用。

**共通実装ルール：**
- Entity サイズ：6m×6m の平面（overlayDistance=1.5m で ±60度をカバー）
- 向き設定：`entity.orientation = headOrientation`（`look(at:)` は平面が傾くためNG）
- `CGContext.clear()` で初期化後に `drawRadialGradient`（`fill()` では透明にならない）

| 症状 | テクスチャ構造 | スムージング |
|---|---|---|
| 視野狭窄（緑内障） | 中心透明・外周ほど黒アルファが上がるグラデーション | α=0.15 |
| 網膜色素変性症 | 中心だけ透明（小さい円）・外周は黒 | α=0.15 |
| 中心暗点（加齢黄斑変性） | 中心が黒不透明・外縁が透明のグラデーション | α=0.15 |
| 飛蚊症 | 7個の半透明球体 Entity を `FloaterOffsetComponent` で分散配置 | α=0.04（硝子体の慣性感） |

---

## 画面構成

### 起動画面（ContentView）

- アプリアイコン・タイトル
- 症状ごとの撮影ヒント一覧（2列グリッド）
- 空間写真の必要条件注意書き
- 「空間写真を選ぶ」ボタン → PHPickerViewController が開く
- 免責事項テキスト

### Full Immersion Space（ImmersiveView）

空間写真を選択すると即座に Full Immersion Space に移行。

**ドームメッシュ**
- 前方のみ（約90〜120度の範囲）
- 空間写真が全天球でなく約60〜80度の画角のため、球体にすると背後が空白になる
- ドーム外は暗い背景（グラデーション）で自然に馴染ませる

**フローティングパネル（FloatingPanelView）**
- 正面左上に常駐
- 症状の選択・強度スライダー
- 「写真を変更」ボタン（メインウィンドウを再表示）
- 「？」ボタン → InfoView（症状説明カード）を開閉

**体験開始時の注意（EntryNoticeView）**
- 空間に入った直後に表示
- 5秒後に自動フェードアウト

### 症状説明（InfoView）

フローティングパネルの「？」をタップすると空間内に浮かぶカード形式で表示。
- 症状名・概要・詳細説明
- 免責事項

---

## 技術的実装の詳細

### 空間写真の取り扱い

空間写真は2枚の画像（左目・右目）が1つの HEIC ファイルにパッケージされている。

**取得フロー**
```
PHPickerConfiguration(photoLibrary: .shared())
  → result.assetIdentifier
  → PHAsset.fetchAssets(withLocalIdentifiers:)
  → PHAssetResource.assetResources(for:)  ← .photo タイプを選択
  → PHAssetResourceManager.requestData   ← 完全な HEIC バイナリ
  → CGImageSourceCreateWithData
  → CGImageSourceCopyProperties          ← ここで kCGImagePropertyGroups を取得
  → GroupImageIndexLeft=0, GroupImageIndexRight=1
  → CGImageSourceCreateImageAtIndex(0) / CGImageSourceCreateImageAtIndex(1)
```

**重要な注意点**
- `PHPickerConfiguration()` では NSItemProvider 経由で変換済みの単一フレームしか取得できない
- `kCGImagePropertyGroups` は `CGImageSourceCopyPropertiesAtIndex` には**存在しない**。`CGImageSourceCopyProperties`（インデックスなし・ソース全体）のプロパティに存在する
- Vision Pro 撮影の空間写真は compatible brand `MiHB`、`ster` グループで左右が定義される

### Left/Right テクスチャの表示

ShaderGraph マテリアル `StereoscopicMaterial.usda` の構成：

```
LeftTexture (asset input)  → LeftImageSampler  → CameraIndexSwitch.left
RightTexture (asset input) → RightImageSampler → CameraIndexSwitch.right
                                                    ↓
                                               UnlitSurface
```

`CameraIndexSwitch`（`ND_realitykit_geometry_switch_cameraindex_color3`）が
左目レンダリング時は Left を、右目レンダリング時は Right を自動選択する。

### Core Image フィルターパイプライン

```
CGImage（元画像）
  → CIImage
  → フィルター適用（症状・強度に応じて）
  → CIContext.createCGImage
  → TextureResource(image:)
  → ShaderGraph マテリアルの LeftTexture / RightTexture に設定
```

---

## 開発フェーズ

### フェーズ1（完了）

- [x] PHPickerViewController で空間写真を選択
- [x] PHAssetResourceManager で完全 HEIC 取得
- [x] CGImageSource で左右フレームを正しく抽出
- [x] ドームメッシュ展開・Full Immersion Space 表示
- [x] ShaderGraph CameraIndexSwitch による左右テクスチャ切り替え（立体感の保持）
- [x] フローティングパネルUI
- [x] 色覚異常・白内障・老眼・乱視（Core Image フィルター方式）
- [x] 症状説明 InfoView・体験開始免責事項 EntryNoticeView
- [x] 日英ローカライゼーション

### フェーズ2（完了）

- [x] 中心暗点（ヘッドトラッキング連動・Entity オーバーレイ方式）
- [x] 飛蚊症（ヘッドトラッキング連動・Entity オーバーレイ方式）
- [x] 視野狭窄（ヘッドトラッキング連動・Entity オーバーレイ方式に移行）
- [x] 網膜色素変性症（ヘッドトラッキング連動・Entity オーバーレイ方式に移行）
- [x] App Store 申請（審査提出済み）

### フェーズ3（未着手）

#### 機能追加

- [ ] 症状の重ねがけモード（複数症状の同時適用）
  - 例：白内障 + 視野狭窄など、高齢者が実際に経験する複合症状の再現
  - CI方式 + Entity方式の組み合わせ、CI方式同士の組み合わせの両方に対応が必要
- [ ] 当事者の声の追加
  - InfoView に「この症状を持つ方の声」（一人称の短いコメント）を掲載
  - コンテンツの収集・監修が必要
- [ ] 症状プリセット（シナリオモード）
  - 「70代の一般的な見え方」など、複数症状+強度をまとめたプリセットを選択可能に
  - 重ねがけモードの上位機能として実装
  - 展示・研修用途で「スライダー操作なしですぐ体験」を実現
- [ ] サンプル空間写真のバンドル
  - 空間写真を持っていないユーザー向けに、アプリ内に1〜2枚のサンプルを同梱
  - 初回体験のハードルを大幅に下げる（ダウンロード即体験可能）
  - 容量とのトレードオフに注意（空間写真は1枚 10〜20MB）

#### UX改善

- [ ] 症状選択UIのグリッド化
  - 現在9ボタン横並び（HStack）→ 2行グリッド（LazyVGrid）に変更
  - Vision Pro の空間UIでのタップしやすさ向上
- [ ] 症状切り替え時のトランジション
  - 即座にフィルター適用ではなく、1秒程度かけてフェードイン/アウト
  - 体験としての自然さ向上
- [ ] 強度スライダーのスロットル
  - CIフィルター方式の症状でスライダードラッグ中の更新頻度を制限（例：0.1秒間隔）
  - パフォーマンス安定化
- [ ] 写真の履歴管理
  - 最近使った写真の一覧表示、毎回選び直す手間を省く
- [ ] 初回オンボーディング
  - 空間写真の撮り方チュートリアル
  - 空間写真を持っていないユーザーの離脱防止
- [ ] フローティングパネルの視線追従（パネルのリポジション）
  - 頭を大きく回した場合にパネルが視界外に取り残される問題への対応
  - 「パネルを手元に呼ぶ」ボタン、または緩やかな視線追従で解決
- [ ] エラーメッセージのローカライズ
  - SpatialPhotoError の errorDescription が日本語ハードコーディング
  - String(localized:) に統一して日英対応

#### 技術改善

- [ ] ImmersiveView の分割
  - 現在 ImmersiveView.swift が 800行超の巨大ファイル
  - Entity生成（makeScotomaEntity 等）をヘルパーファイルに分離
  - CI フィルター処理を専用サービスに分離（例：ConditionFilterService.swift）
  - ヘッドトラッキング更新ループを専用ファイルに分離
- [ ] Entity オーバーレイの生成を非同期化
  - 現在 makeContent クロージャ内で全 Entity を同期生成している
  - テクスチャ生成（CGContext → TextureResource）を Task.detached に移動
  - Immersive Space の初期表示速度を改善

#### プロダクト品質

- [ ] アクセシビリティ対応
  - VoiceOver での操作確認
  - Dynamic Type 対応
  - 症状ボタンの accessibilityLabel・accessibilityHint 追加
- [ ] 体験の共有機能（スクリーンショット + SNSシェア）
- [ ] Analytics / フィードバック
  - どの症状が最も使われているか、どの強度で体験されているかの匿名統計
  - 展示運用時に「どの症状が反響を得たか」を把握するため
  - プライバシーポリシーとの整合に注意

---

## 倫理的配慮

視覚障害の当事者から「こんな単純じゃない」「軽く扱っている」と言われるリスクがある。

- 症状説明に当事者の声（一人称の短いコメント）を入れる（フェーズ2）
- 「これは再現ではない」を強くかつ自然に明示する
- 教育用途であることをApp Store説明文・アプリ内で明確化

---

## 想定用途・戦略的ポジション

大量DLを狙う一般アプリではなく、体験・教育・展示向け。

- Apple Store店頭デモ
- 医療学会・眼科学会でのデモ展示
- 企業ダイバーシティ研修
- 学校・福祉施設での教材

アプリ内に必ず以下を表示すること：

```
このアプリが提供する体験は近似的なシミュレーションです。
実際の視覚症状は個人差があり、
このアプリで完全に再現することはできません。
医療診断・治療の代替として使用しないでください。
視覚に関する症状がある場合は眼科医にご相談ください。
```
