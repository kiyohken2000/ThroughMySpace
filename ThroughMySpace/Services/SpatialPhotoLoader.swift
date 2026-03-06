// SpatialPhotoLoader.swift
// ThroughMySpace
//
// 空間写真（Spatial Photo）から左目用・右目用の画像を取り出すサービス。
//
// 【React Native との対比】
// React Native で fetch() してデータを取り出す感覚に近い。
// PHAsset = ファイルへの参照（URLみたいなもの）
// PHAssetResourceManager = 実際にデータをダウンロード/読み込むもの
// CGImageSource = 画像ファイルのパーサー（複数フレームを持てる）
//
// 空間写真の構造：
// HEIC ファイル
// ├── index 0: 左目用 または 右目用（プライマリ）
// └── index 1: もう片方の目用
// kCGImagePropertyGroupImageIsLeftImage / IsRightImage で判定する

import Foundation
import Photos
import ImageIO
import RealityKit
import CoreImage

// 取り出した左右画像のペア
struct StereoImagePair {
    let left: CGImage
    let right: CGImage
}

// 読み込みエラーの種類
enum SpatialPhotoError: LocalizedError {
    case notSpatialPhoto          // 空間写真でない（通常の写真）
    case imageLoadFailed          // 画像データの取得失敗
    case leftImageNotFound        // 左目画像が見つからない
    case rightImageNotFound       // 右目画像が見つからない
    case resourceDataFailed       // PHAssetResourceのデータ取得失敗

    var errorDescription: String? {
        switch self {
        case .notSpatialPhoto:    return "選択された写真は空間写真ではありません"
        case .imageLoadFailed:    return "画像の読み込みに失敗しました"
        case .leftImageNotFound:  return "左目用画像が見つかりませんでした"
        case .rightImageNotFound: return "右目用画像が見つかりませんでした"
        case .resourceDataFailed: return "写真データの取得に失敗しました"
        }
    }
}

@MainActor
class SpatialPhotoLoader {

    // ------------------------------------------------------------------
    // PHAsset から左右の CGImage を取り出す
    //
    // 流れ：
    // 1. PHAssetResourceManager でデータ取得を試みる（空間写真向け）
    // 2. 失敗したら PHImageManager で CGImage を直接取得（通常写真・シミュレーター向け）
    // 3. CGImageSource で画像をパースし、左右メタデータで仕分け
    // 4. 左右ペアを返す（右がなければ左を両目に使う）
    // ------------------------------------------------------------------
    func loadStereoImages(from asset: PHAsset) async throws -> StereoImagePair {

        // まず PHAssetResourceManager でデータ取得を試みる
        // 空間写真（HEIC）は複数画像が入っているためこちらが必要
        if let imageSource = await loadImageSourceViaResourceManager(from: asset) {
            let pair = extractStereoImages(from: imageSource)
            if let left = pair.left {
                return StereoImagePair(left: left, right: pair.right ?? left)
            }
        }

        // フォールバック：PHImageManager で CGImage を直接取得
        // シミュレーターや通常のJPG写真はこちらで確実に取れる
        guard let cgImage = await loadCGImageViaImageManager(from: asset) else {
            throw SpatialPhotoError.imageLoadFailed
        }

        // 通常写真は左右同一（立体感なし）でフォールバック
        return StereoImagePair(left: cgImage, right: cgImage)
    }

    // ------------------------------------------------------------------
    // Data から直接 StereoImagePair を取得する
    //
    // nonisolated にすることで Task.detached（バックグラウンドスレッド）から
    // 呼び出せる。CGImageSource API はスレッドセーフなので問題ない。
    // メインスレッドで大きな画像をパースするとウォッチドッグに殺されるため、
    // 必ずバックグラウンドから呼ぶこと。
    // ------------------------------------------------------------------
    nonisolated func loadStereoImages(from data: Data) throws -> StereoImagePair {
        print("✅ Data から ImageSource を生成: \(data.count) bytes")

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw SpatialPhotoError.imageLoadFailed
        }

        let pair = extractStereoImages(from: imageSource)
        guard let left = pair.left else {
            throw SpatialPhotoError.leftImageNotFound
        }
        return StereoImagePair(left: left, right: pair.right ?? left)
    }

    // ------------------------------------------------------------------
    // PHAssetResourceManager 経由でデータを取得し CGImageSource を返す
    // 失敗した場合は nil を返す（エラーを投げない）
    // ------------------------------------------------------------------
    private func loadImageSourceViaResourceManager(from asset: PHAsset) async -> CGImageSource? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let photoResource = resources.first(where: { $0.type == .photo }) else {
            return nil
        }
        guard let imageData = try? await loadResourceData(photoResource) else {
            return nil
        }
        return CGImageSourceCreateWithData(imageData as CFData, nil)
    }

    // ------------------------------------------------------------------
    // CGImageSource から左右画像を抽出する
    // 空間写真なら kCGImagePropertyGroups で判定
    // 通常写真なら index 0 を left として返す
    // ------------------------------------------------------------------
    private nonisolated func extractStereoImages(from imageSource: CGImageSource) -> (left: CGImage?, right: CGImage?) {
        let imageCount = CGImageSourceGetCount(imageSource)
        var leftImage: CGImage?
        var rightImage: CGImage?

        // kCGImageSourceShouldCacheImmediately: true を指定することで
        // CGImageSource が解放される前にピクセルデータを強制デコードする。
        // これにより imageSource のライフタイムに依存しない独立した CGImage になる。
        // リリースビルド（最適化あり）で imageSource が早期解放されてもデータが失われない。
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true
        ]

        for index in 0..<imageCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil)
                    as? [CFString: Any] else { continue }

            // kCGImagePropertyGroups = 空間写真の左右ペア情報
            if let groups = properties[kCGImagePropertyGroups] as? [[CFString: Any]],
               let group = groups.first {
                let isLeft  = group[kCGImagePropertyGroupImageIsLeftImage]  as? Bool ?? false
                let isRight = group[kCGImagePropertyGroupImageIsRightImage] as? Bool ?? false
                guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, index, decodeOptions as CFDictionary) else { continue }
                if isLeft  { leftImage  = cgImage }
                if isRight { rightImage = cgImage }
            } else if index == 0, leftImage == nil {
                // グループ情報がない通常写真は index 0 を使う
                leftImage = CGImageSourceCreateImageAtIndex(imageSource, index, decodeOptions as CFDictionary)
            }
        }

        return (leftImage, rightImage)
    }

    // ------------------------------------------------------------------
    // PHImageManager 経由で CGImage を取得する
    // シミュレーター・通常写真・iCloud写真でも確実に動く
    //
    // visionOS では UIKit が使えないため requestImage（UIImage返却）は使えない。
    // requestImageDataAndOrientation でバイナリデータを取得し、
    // CGImageSource → CGImage に変換する。
    //
    // 注意：withCheckedContinuation は必ず1回だけ resume を呼ぶ必要がある。
    // コールバックが複数回来る（degraded → 最終版）ケースに対応するため
    // 「最初に data が取れた時点で resume する」設計にする。
    // ------------------------------------------------------------------
    private func loadCGImageViaImageManager(from asset: PHAsset) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            // .opportunistic = 低解像度版を先に返し、その後高解像度版を返す
            // .highQualityFormat = 高解像度版のみ（シミュレーターで data=nil になることがある）
            // → シミュレーター安定性のため .opportunistic を使い、最初のデータを採用する
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            // resumeOnce: continuation を複数回呼ばないための保護フラグ
            // withCheckedContinuation は2回 resume するとクラッシュする
            var hasResumed = false

            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, info in
                // すでに resume 済みなら何もしない
                guard !hasResumed else { return }

                // data が nil = エラーまたはキャンセル
                guard let data else {
                    // エラー情報をログに出す
                    if let error = info?[PHImageErrorKey] as? Error {
                        print("⚠️ PHImageManager エラー: \(error)")
                    }
                    hasResumed = true
                    continuation.resume(returning: nil)
                    return
                }

                // Data → CGImageSource → CGImage
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    hasResumed = true
                    continuation.resume(returning: nil)
                    return
                }

                hasResumed = true
                continuation.resume(returning: cgImage)
            }
        }
    }

    // ------------------------------------------------------------------
    // CGImage → RealityKit の TextureResource に変換
    //
    // TextureResource = GPUにアップロードされたテクスチャデータ
    // React Native で言うと Image のソースをメモリから読み込む感じ
    // ------------------------------------------------------------------
    func makeTextureResource(from cgImage: CGImage, name: String) async throws -> TextureResource {
        let options = TextureResource.CreateOptions(semantic: .color)
        return try await TextureResource(image: cgImage, withName: name, options: options)
    }

    // ------------------------------------------------------------------
    // PHAssetResource → Data（非同期）
    //
    // PHAssetResourceManager.requestData は completion ベースの古いAPI。
    // withCheckedThrowingContinuation で async/await に変換する。
    // React Native で言うと、コールバックを Promise に変換するラッパー。
    // ------------------------------------------------------------------
    private func loadResourceData(_ resource: PHAssetResource) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            var imageData = Data()
            let manager = PHAssetResourceManager.default()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true  // iCloud からもダウンロード可

            manager.requestData(for: resource, options: options) { chunk in
                imageData.append(chunk)
            } completionHandler: { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: imageData)
                }
            }
        }
    }
}
