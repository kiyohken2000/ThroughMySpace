//
//  AppModel.swift
//  ThroughMySpace
//
//  Created by admin on 2026/03/03.
//

// AppModel.swift
// アプリ全体の状態を管理するクラス。
//
// 【React Native との対比】
// React Native の Context + useReducer に相当する。
// @Observable マクロ = SwiftUI が自動的に変更を検知して再描画する仕組み。
// React の useState/useReducer が自動でできるイメージ。
//
// データの流れ：
// ContentView（写真選択）
//   → selectedStereoTextures にテクスチャを格納
//     → ImmersiveView が監視して球体に貼り付ける

import SwiftUI
import RealityKit

// 左右テクスチャのペア（ImmersiveView に渡す）
struct StereoTextures {
    let left: TextureResource
    let right: TextureResource
}

// 左右 CGImage のペア（フィルター処理用に保持）
// TextureResource → CGImage の変換コストを避けるため元画像を直接保存する
struct StereoCGImages {
    let left: CGImage
    let right: CGImage
}

/// アプリ全体の状態を管理
@MainActor
@Observable
class AppModel {
    // Immersive Space の識別子（ThroughMySpaceApp.swift と一致させる）
    let immersiveSpaceID = "ImmersiveSpace"

    // メインウィンドウの識別子
    let mainWindowID = "MainWindow"

    // Immersive Space の開閉状態
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed

    // -------------------------------------------------------
    // 選択された空間写真の左右テクスチャ
    // nil = まだ写真が選ばれていない
    // ImmersiveView はこの値を監視して球体を更新する
    // -------------------------------------------------------
    var selectedStereoTextures: StereoTextures? = nil

    // フィルター処理用の元 CGImage ペア（TextureResource から変換せずに保持）
    // ImmersiveView の extractCGImage を廃止してこちらを直接使う
    var sourceStereoImages: StereoCGImages? = nil

    // テクスチャが更新されるたびにインクリメントするカウンター
    // onChange(of: textureVersion) で確実にトリガーをかけるために使う
    var textureVersion: Int = 0

    // 写真の読み込み中かどうか（ローディングUI用）
    var isLoadingPhoto: Bool = false

    // 読み込みエラーメッセージ（nilならエラーなし）
    var photoLoadError: String? = nil

    // -------------------------------------------------------
    // 現在選択中の視覚症状設定
    // ImmersiveView はこの値を監視してシェーダーを切り替える
    // -------------------------------------------------------
    var conditionSetting: ConditionSetting = ConditionSetting()

}
