//
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

struct JunchatTetrisPoint: Hashable {
    var x: Int
    var y: Int
}

enum JunchatTetrominoKind: CaseIterable {
    case i
    case o
    case t
    case s
    case z
    case j
    case l
    
    func offsets(rotation: Int) -> [JunchatTetrisPoint] {
        let rotations = switch self {
        case .i:
            [
                [JunchatTetrisPoint(x: 0, y: 1), .init(x: 1, y: 1), .init(x: 2, y: 1), .init(x: 3, y: 1)],
                [JunchatTetrisPoint(x: 2, y: 0), .init(x: 2, y: 1), .init(x: 2, y: 2), .init(x: 2, y: 3)]
            ]
        case .o:
            [
                [JunchatTetrisPoint(x: 1, y: 0), .init(x: 2, y: 0), .init(x: 1, y: 1), .init(x: 2, y: 1)]
            ]
        case .t:
            [
                [JunchatTetrisPoint(x: 1, y: 0), .init(x: 0, y: 1), .init(x: 1, y: 1), .init(x: 2, y: 1)],
                [JunchatTetrisPoint(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 2, y: 1), .init(x: 1, y: 2)],
                [JunchatTetrisPoint(x: 0, y: 1), .init(x: 1, y: 1), .init(x: 2, y: 1), .init(x: 1, y: 2)],
                [JunchatTetrisPoint(x: 1, y: 0), .init(x: 0, y: 1), .init(x: 1, y: 1), .init(x: 1, y: 2)]
            ]
        case .s:
            [
                [JunchatTetrisPoint(x: 1, y: 0), .init(x: 2, y: 0), .init(x: 0, y: 1), .init(x: 1, y: 1)],
                [JunchatTetrisPoint(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 2, y: 1), .init(x: 2, y: 2)]
            ]
        case .z:
            [
                [JunchatTetrisPoint(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 2, y: 1)],
                [JunchatTetrisPoint(x: 2, y: 0), .init(x: 1, y: 1), .init(x: 2, y: 1), .init(x: 1, y: 2)]
            ]
        case .j:
            [
                [JunchatTetrisPoint(x: 0, y: 0), .init(x: 0, y: 1), .init(x: 1, y: 1), .init(x: 2, y: 1)],
                [JunchatTetrisPoint(x: 1, y: 0), .init(x: 2, y: 0), .init(x: 1, y: 1), .init(x: 1, y: 2)],
                [JunchatTetrisPoint(x: 0, y: 1), .init(x: 1, y: 1), .init(x: 2, y: 1), .init(x: 2, y: 2)],
                [JunchatTetrisPoint(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 2), .init(x: 1, y: 2)]
            ]
        case .l:
            [
                [JunchatTetrisPoint(x: 2, y: 0), .init(x: 0, y: 1), .init(x: 1, y: 1), .init(x: 2, y: 1)],
                [JunchatTetrisPoint(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 1, y: 2), .init(x: 2, y: 2)],
                [JunchatTetrisPoint(x: 0, y: 1), .init(x: 1, y: 1), .init(x: 2, y: 1), .init(x: 0, y: 2)],
                [JunchatTetrisPoint(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 1, y: 2)]
            ]
        }
        
        return rotations[rotation % rotations.count]
    }
}

struct JunchatTetrisPiece: Equatable {
    let kind: JunchatTetrominoKind
    var origin: JunchatTetrisPoint
    var rotation: Int
    
    var cells: [JunchatTetrisPoint] {
        kind.offsets(rotation: rotation).map { .init(x: origin.x + $0.x, y: origin.y + $0.y) }
    }
    
    func movedBy(x: Int, y: Int) -> JunchatTetrisPiece {
        var copy = self
        copy.origin.x += x
        copy.origin.y += y
        return copy
    }
    
    func rotated() -> JunchatTetrisPiece {
        var copy = self
        copy.rotation += 1
        return copy
    }
}

@MainActor
final class JunchatTetrisGame: ObservableObject {
    let boardWidth = 10
    let boardHeight = 20
    
    @Published private(set) var activePiece: JunchatTetrisPiece
    @Published private(set) var nextPiece: JunchatTetrisPiece
    @Published private(set) var lockedBlocks = Set<JunchatTetrisPoint>()
    @Published private(set) var score = 0
    @Published private(set) var level = 1
    @Published private(set) var isRunning = false
    @Published private(set) var isGameOver = false
    
    private let initialSeed: UInt64
    private var randomGenerator: SeededGenerator
    
    init(randomSeed: UInt64 = UInt64(Date().timeIntervalSince1970)) {
        initialSeed = randomSeed
        randomGenerator = SeededGenerator(seed: randomSeed)
        activePiece = Self.makePiece(kind: Self.randomKind(using: &randomGenerator))
        nextPiece = Self.makePiece(kind: Self.randomKind(using: &randomGenerator))
    }
    
    func start() {
        guard !isGameOver else { return }
        isRunning = true
    }
    
    func togglePause() {
        guard !isGameOver else { return }
        isRunning.toggle()
    }
    
    func reset() {
        randomGenerator = SeededGenerator(seed: initialSeed)
        activePiece = Self.makePiece(kind: Self.randomKind(using: &randomGenerator))
        nextPiece = Self.makePiece(kind: Self.randomKind(using: &randomGenerator))
        lockedBlocks = []
        score = 0
        level = 1
        isRunning = false
        isGameOver = false
    }
    
    func tick() {
        guard isRunning else { return }
        
        let moved = activePiece.movedBy(x: 0, y: 1)
        if canPlace(moved) {
            activePiece = moved
        } else {
            lockActivePiece()
        }
    }
    
    func moveLeft() {
        moveActivePiece(x: -1, y: 0)
    }
    
    func moveRight() {
        moveActivePiece(x: 1, y: 0)
    }
    
    func rotate() {
        let rotated = activePiece.rotated()
        if canPlace(rotated) {
            activePiece = rotated
        }
    }
    
    func softDrop() {
        moveActivePiece(x: 0, y: 1)
    }
    
    func hardDrop() {
        while canPlace(activePiece.movedBy(x: 0, y: 1)) {
            activePiece = activePiece.movedBy(x: 0, y: 1)
        }
        lockActivePiece()
    }
    
    func clearCompletedRows() {
        let completedRows = (0..<boardHeight).filter { row in
            (0..<boardWidth).allSatisfy { column in
                lockedBlocks.contains(.init(x: column, y: row))
            }
        }
        
        guard !completedRows.isEmpty else { return }
        
        let completedRowsSet = Set(completedRows)
        lockedBlocks = Set(lockedBlocks.compactMap { block in
            guard !completedRowsSet.contains(block.y) else {
                return nil
            }
            
            let rowsBelow = completedRows.filter { $0 > block.y }.count
            return JunchatTetrisPoint(x: block.x, y: block.y + rowsBelow)
        })
        score += completedRows.count * 100
        level = max(1, score / 500 + 1)
    }
    
    func debugFillRow(_ row: Int) {
        for column in 0..<boardWidth {
            lockedBlocks.insert(.init(x: column, y: row))
        }
    }
    
    func isOccupied(_ point: JunchatTetrisPoint) -> Bool {
        lockedBlocks.contains(point) || activePiece.cells.contains(point)
    }
    
    private func moveActivePiece(x: Int, y: Int) {
        let moved = activePiece.movedBy(x: x, y: y)
        if canPlace(moved) {
            activePiece = moved
        }
    }
    
    private func lockActivePiece() {
        activePiece.cells.forEach { lockedBlocks.insert($0) }
        clearCompletedRows()
        activePiece = nextPiece
        nextPiece = Self.makePiece(kind: Self.randomKind(using: &randomGenerator))
        
        if !canPlace(activePiece) {
            isGameOver = true
            isRunning = false
        }
    }
    
    private func canPlace(_ piece: JunchatTetrisPiece) -> Bool {
        piece.cells.allSatisfy { cell in
            cell.x >= 0 &&
                cell.x < boardWidth &&
                cell.y >= 0 &&
                cell.y < boardHeight &&
                !lockedBlocks.contains(cell)
        }
    }
    
    private static func makePiece(kind: JunchatTetrominoKind) -> JunchatTetrisPiece {
        JunchatTetrisPiece(kind: kind, origin: .init(x: 3, y: 0), rotation: 0)
    }
    
    private static func randomKind(using generator: inout SeededGenerator) -> JunchatTetrominoKind {
        let index = Int(generator.next() % UInt64(JunchatTetrominoKind.allCases.count))
        return JunchatTetrominoKind.allCases[index]
    }
}

private struct SeededGenerator {
    private var state: UInt64
    
    init(seed: UInt64) {
        state = seed == 0 ? 1 : seed
    }
    
    mutating func next() -> UInt64 {
        state = 6_364_136_223_846_793_005 &* state &+ 1_442_695_040_888_963_407
        return state
    }
}
