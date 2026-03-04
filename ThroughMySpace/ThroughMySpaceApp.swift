//
//  ThroughMySpaceApp.swift
//  ThroughMySpace
//
//  Created by admin on 2026/03/03.
//

import SwiftUI

@main
struct ThroughMySpaceApp: App {

    @State private var appModel = AppModel()

    var body: some Scene {
        // id を指定することで dismissWindow(id:) で閉じられるようになる
        WindowGroup(id: appModel.mainWindowID) {
            ContentView()
                .environment(appModel)
        }
        // ウィンドウの初期サイズを指定（横幅を抑えて縦長に）
        .defaultSize(width: 480, height: 720)

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
