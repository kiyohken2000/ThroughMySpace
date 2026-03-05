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

    // -------------------------------------------------------
    // アイトラッキング：スムージング済みの視線位置（正規化UV座標）
    //
    // 値の範囲：0.0〜1.0（左上原点）
    // (0.5, 0.5) = 画面中央（正面を見ているとき）
    //
    // WorldTrackingProvider でヘッドの向きを取得し、
    // ドームのUV座標に変換してここに格納する。
    // ImmersiveView の中心暗点・飛蚊症フィルターがこの値を読む。
    // -------------------------------------------------------
    var gazeNormalized: SIMD2<Float> = SIMD2<Float>(0.5, 0.5)
}
