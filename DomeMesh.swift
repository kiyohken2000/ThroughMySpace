// DomeMesh.swift
// ThroughMySpace
//
// 前方ドーム（半球）メッシュを生成するユーティリティ。
//
// 【なぜ球体ではなくドームか】
// 空間写真は全天球ではなく約60〜80度の画角しかない。
// 球体に貼ると背後が空白になり没入感が削がれる。
// ドーム状メッシュにすることで「見える範囲」に自然に収まる。
//
// 【メッシュの仕組み】
// 球面座標（水平角 phi × 垂直角 theta）でグリッドを作り、
// 各頂点の UV を空間写真の画像座標に対応させる。
//
// 【React Native との対比】
// Three.js の SphereGeometry(radius, widthSegments, heightSegments, phiStart, phiLength)
// に相当する概念。ただし法線は内向き（カメラ側）に設定する。

import RealityKit
import simd

enum DomeMesh {

    // ------------------------------------------------------------------
    // ドームメッシュを生成する
    //
    // radius      : ドームの半径（メートル）
    // hFovDeg     : 水平方向の視野角（度）。空間写真は約70〜80度
    // vFovDeg     : 垂直方向の視野角（度）。空間写真は約60〜70度
    // hSegments   : 水平方向の分割数（多いほど滑らか）
    // vSegments   : 垂直方向の分割数
    //
    // 返値：MeshResource（ModelEntity に渡せるメッシュ）
    // ------------------------------------------------------------------
    static func generate(
        radius: Float = 3.0,
        hFovDeg: Float = 120.0,
        vFovDeg: Float = 90.0,
        hSegments: Int = 60,
        vSegments: Int = 45
    ) throws -> MeshResource {

        // 度 → ラジアン変換
        let hFov = hFovDeg * .pi / 180.0   // 水平視野角（ラジアン）
        let vFov = vFovDeg * .pi / 180.0   // 垂直視野角（ラジアン）

        // 水平角の範囲：中心 (phi=0 = 正面) を中心に左右に広げる
        // visionOS の座標系：Z+ が後方、Z- が前方（ユーザーが向く方向）
        let phiStart = -hFov / 2.0         // 左端
        let phiEnd   =  hFov / 2.0         // 右端

        // 垂直角の範囲：0 = 水平面、上方向がプラス
        let thetaStart = -vFov / 2.0       // 下端
        let thetaEnd   =  vFov / 2.0       // 上端

        // 頂点配列・法線・UV・インデックス
        var positions: [SIMD3<Float>] = []
        var normals:   [SIMD3<Float>] = []
        var uvs:       [SIMD2<Float>] = []
        var indices:   [UInt32]       = []

        // ------------------------------------------------------------------
        // 頂点生成
        // グリッドを (hSegments+1) × (vSegments+1) の格子点で作る
        // React Native の FlatList の index 計算と同じ感覚
        // ------------------------------------------------------------------
        for vi in 0...vSegments {
            // 垂直方向の割合 [0, 1]
            let vt = Float(vi) / Float(vSegments)
            // 垂直角（ラジアン）：下端から上端へ
            let theta = thetaStart + vt * (thetaEnd - thetaStart)

            for hi in 0...hSegments {
                // 水平方向の割合 [0, 1]
                let ht = Float(hi) / Float(hSegments)
                // 水平角（ラジアン）：左端から右端へ
                let phi = phiStart + ht * (phiEnd - phiStart)

                // 球面座標 → デカルト座標変換
                // cos(theta) = 水平面への射影の長さ
                // sin(phi)   = X方向（左右）
                // cos(phi)   = Z方向（前後）
                // sin(theta) = Y方向（上下）
                let x =  radius * cos(theta) * sin(phi)
                let y =  radius * sin(theta)
                let z = -radius * cos(theta) * cos(phi)  // 前方が -Z

                positions.append(SIMD3<Float>(x, y, z))

                // 法線：内向き（頂点から原点への方向）
                // 外向き法線を反転させることで内側から見えるようにする
                let nx = -x / radius
                let ny = -y / radius
                let nz = -z / radius
                normals.append(SIMD3<Float>(nx, ny, nz))

                // UV 座標：画像の左上 (0,0) → 右下 (1,1) に対応させる
                // 画像座標は左上原点（Y下向き）のため、V軸を反転する必要がある。
                // vt=0（下端）→ 1.0 - 0.0 = 1.0（画像の下辺）
                // vt=1（上端）→ 1.0 - 1.0 = 0.0（画像の上辺）
                uvs.append(SIMD2<Float>(ht, 1.0 - vt))
            }
        }

        // ------------------------------------------------------------------
        // インデックス生成（三角形ポリゴン）
        //
        // グリッドの各セルを2つの三角形に分割する
        // (tl)---(tr)
        //  |  \   |
        // (bl)---(br)
        // → 三角形1: tl, bl, br
        // → 三角形2: tl, br, tr
        //
        // 【注意】法線が内向きのため、三角形の巻き順（winding order）を
        // 通常と逆にする必要がある（外向きは反時計回り → 内向きは時計回り）
        // ------------------------------------------------------------------
        let stride = hSegments + 1  // 水平方向の頂点数

        for vi in 0..<vSegments {
            for hi in 0..<hSegments {
                let tl = UInt32(vi * stride + hi)           // 左上
                let tr = UInt32(vi * stride + hi + 1)       // 右上
                let bl = UInt32((vi + 1) * stride + hi)     // 左下
                let br = UInt32((vi + 1) * stride + hi + 1) // 右下

                // 時計回り（内向き法線のため）
                indices.append(contentsOf: [tl, br, bl])
                indices.append(contentsOf: [tl, tr, br])
            }
        }

        // ------------------------------------------------------------------
        // MeshDescriptor を組み立てて MeshResource に変換
        //
        // MeshDescriptor = Three.js の BufferGeometry に相当
        // 頂点データとインデックスを渡してメッシュを定義する
        // ------------------------------------------------------------------
        var descriptor = MeshDescriptor(name: "Dome")
        descriptor.positions  = MeshBuffers.Positions(positions)
        descriptor.normals    = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)

        return try MeshResource.generate(from: [descriptor])
    }
}
