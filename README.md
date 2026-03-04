# Through My Space

**「あなたが毎日見ているこの空間を、別の目で見てください。」**

自分の空間写真を使って視覚症状を体験する visionOS アプリ。

---

## 概要

視野狭窄・色覚異常などの視覚症状を、**自分が撮影した空間写真**に適用して体験できる Apple Vision Pro アプリ。

他人が用意したストック素材ではなく「自分の部屋・自分の職場」が変容することで、視覚障害の当事者への共感と理解を生む。

> このアプリが提供する体験は近似的なシミュレーションです。実際の視覚症状は個人差があります。医療診断・治療の代替として使用しないでください。

---

## 特徴

- **自分の空間で体験** — フォトライブラリの空間写真（Spatial Photo）をそのまま使用
- **Full Immersion Space** — Vision Pro の没入空間で全周囲を包む体験
- **立体感の保持** — 空間写真の左目用・右目用テクスチャを分離してドームに投影
- **リアルタイム切り替え** — 症状・強度をフローティングパネルでその場で変更

---

## 対応する視覚症状

### フェーズ 1（実装済み）

| 症状 | 説明 |
|---|---|
| 視野狭窄（緑内障） | 周辺視野が失われていく体験。強度スライダーで段階調整 |
| 色覚異常 | 赤緑色盲（第1・第2）、青黄色盲（第3）の3タイプ対応 |

### フェーズ 2（実装予定）

- 中心暗点（加齢黄斑変性）— アイトラッキング連動
- 白内障 — Bloom 効果によるハレーション表現
- 飛蚊症 — アイトラッキング連動
- 網膜色素変性症

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
- **RealityKit** — 3D 空間・ドームメッシュ
- **Core Image** — 視覚フィルター（視野狭窄・色覚異常）
- **PhotosUI** — 空間写真の読み込み
- **Metal** — テクスチャ転送（MTLTexture → CGImage）

### フィルター実装について

visionOS では `CustomMaterial`（Metal 直書き）が使用不可のため、CPU 側の Core Image でフィルターを適用し `UnlitMaterial` で表示する方式を採用。

```
空間写真 (TextureResource)
  → MTLTexture (rgba8Unorm_srgb)  ← sRGB保持のため
  → CGImage
  → Core Image フィルター適用
  → TextureResource
  → UnlitMaterial → ドームメッシュ
```

---

## プロジェクト構成

```
ThroughMySpace/
├── Models/
│   └── Condition.swift          # 症状データモデル
├── Views/
│   ├── ContentView.swift        # メイン画面・写真選択
│   ├── ImmersiveView.swift      # Full Immersion 体験本体
│   ├── FloatingPanelView.swift  # 症状選択フローティングパネル
│   ├── InfoView.swift           # 症状説明（空間内に浮かぶ）
│   └── EntryNoticeView.swift    # 体験開始時の免責事項カード
├── Services/
│   └── SpatialPhotoLoader.swift # 空間写真の読み込み・左右分離
├── DomeMesh.swift               # 前方ドーム状メッシュ生成
└── Packages/RealityKitContent/  # Reality Composer Pro アセット
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
