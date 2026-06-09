//
// Copyright 2026 Wenyidao Technology (Guangzhou) Co., Ltd.
//

@testable import ElementX
import Testing

@MainActor
struct AppCoordinatorVersionTests {
    @Test
    func migrationVersionAcceptsAppStoreTwoComponentVersions() throws {
        let version = try #require(AppCoordinator.migrationVersion(from: "1.5"))
        
        #expect(version.description == "1.5.0")
    }
    
    @Test
    func migrationVersionKeepsSemverVersions() throws {
        let version = try #require(AppCoordinator.migrationVersion(from: "1.5.1"))
        
        #expect(version.description == "1.5.1")
    }
    
    @Test
    func migrationVersionRejectsNonNumericVersions() {
        #expect(AppCoordinator.migrationVersion(from: "review-build") == nil)
    }
}
