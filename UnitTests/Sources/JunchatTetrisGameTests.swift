//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Testing

@MainActor
struct JunchatTetrisGameTests {
    @Test
    func newGameStartsEmptyAndStopped() {
        let game = JunchatTetrisGame(randomSeed: 1)
        
        #expect(game.score == 0)
        #expect(game.level == 1)
        #expect(!game.isRunning)
        #expect(game.lockedBlocks.isEmpty)
        #expect(game.boardWidth == 10)
        #expect(game.boardHeight == 20)
    }
    
    @Test
    func startPauseAndReset() {
        let game = JunchatTetrisGame(randomSeed: 1)
        
        game.start()
        #expect(game.isRunning)
        
        game.togglePause()
        #expect(!game.isRunning)
        
        game.reset()
        #expect(game.score == 0)
        #expect(game.level == 1)
        #expect(!game.isRunning)
    }
    
    @Test
    func movingPieceChangesColumnWithinBounds() {
        let game = JunchatTetrisGame(randomSeed: 1)
        let startingColumn = game.activePiece.origin.x
        
        game.moveLeft()
        #expect(game.activePiece.origin.x == startingColumn - 1)
        
        for _ in 0..<20 {
            game.moveLeft()
        }
        #expect(game.activePiece.cells.allSatisfy { $0.x >= 0 })
        
        for _ in 0..<30 {
            game.moveRight()
        }
        #expect(game.activePiece.cells.allSatisfy { $0.x < game.boardWidth })
    }
    
    @Test
    func hardDropLocksCurrentPieceAndAdvancesNextPiece() {
        let game = JunchatTetrisGame(randomSeed: 1)
        let firstKind = game.activePiece.kind
        
        game.hardDrop()
        
        #expect(!game.lockedBlocks.isEmpty)
        #expect(game.activePiece.kind != firstKind || game.lockedBlocks.count > game.activePiece.cells.count)
    }
    
    @Test
    func clearingFilledRowsIncreasesScore() {
        let game = JunchatTetrisGame(randomSeed: 1)
        game.debugFillRow(game.boardHeight - 1)
        
        game.clearCompletedRows()
        
        #expect(game.score == 100)
        #expect(game.lockedBlocks.isEmpty)
    }
}
