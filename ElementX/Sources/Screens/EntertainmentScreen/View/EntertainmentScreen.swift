//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct EntertainmentScreen: View {
    @StateObject private var game = JunchatTetrisGame()
    
    private let timer = Timer.publish(every: 0.65, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                board
                controls
            }
            .padding(16)
        }
        .background(.compound.bgCanvasDefault)
        .navigationTitle("娱乐")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(timer) { _ in game.tick() }
    }
    
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            metric(title: "分数", value: "\(game.score)")
            metric(title: "等级", value: "\(game.level)")
            metric(title: "下一个", value: String(describing: game.nextPiece.kind).uppercased())
        }
    }
    
    private func metric(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.compound.bodySM)
                .foregroundColor(.compound.textSecondary)
            Text(value)
                .font(.compound.headingMD)
                .foregroundColor(.compound.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .padding(.horizontal, 8)
        .background(.compound.bgSubtleSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private var board: some View {
        GeometryReader { geometry in
            let cellSize = floor(min(geometry.size.width / CGFloat(game.boardWidth),
                                     geometry.size.height / CGFloat(game.boardHeight)))
            
            VStack(spacing: 1) {
                ForEach(0..<game.boardHeight, id: \.self) { row in
                    HStack(spacing: 1) {
                        ForEach(0..<game.boardWidth, id: \.self) { column in
                            let point = JunchatTetrisPoint(x: column, y: row)
                            Rectangle()
                                .fill(game.isOccupied(point) ? Color.green : Color(.secondarySystemBackground))
                                .overlay(
                                    Rectangle()
                                        .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                                )
                                .frame(width: cellSize, height: cellSize)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .frame(width: cellSize * CGFloat(game.boardWidth) + 9,
                   height: cellSize * CGFloat(game.boardHeight) + 19)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(CGFloat(game.boardWidth) / CGFloat(game.boardHeight), contentMode: .fit)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("俄罗斯方块棋盘")
    }
    
    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                controlButton("开始", systemName: "play.fill") { game.start() }
                controlButton(game.isRunning ? "暂停" : "继续", systemName: "pause.fill") { game.togglePause() }
                controlButton("重开", systemName: "arrow.clockwise") { game.reset() }
            }
            
            HStack(spacing: 12) {
                controlButton("左移", systemName: "arrow.left") { game.moveLeft() }
                controlButton("旋转", systemName: "rotate.right") { game.rotate() }
                controlButton("右移", systemName: "arrow.right") { game.moveRight() }
            }
            
            HStack(spacing: 12) {
                controlButton("下落", systemName: "arrow.down") { game.softDrop() }
                controlButton("到底", systemName: "arrow.down.to.line") { game.hardDrop() }
            }
            
            if game.isGameOver {
                Text("游戏结束")
                    .font(.compound.headingMD)
                    .foregroundColor(.compound.textCriticalPrimary)
            }
        }
    }
    
    private func controlButton(_ title: String, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(.compound.bodyMDSemibold)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(title)
    }
}
