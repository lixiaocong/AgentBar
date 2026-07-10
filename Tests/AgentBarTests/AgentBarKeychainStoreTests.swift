import Testing
@testable import AgentBarCore

@Test
func keychainStoreSeparatesProductionAndDevelopmentVaults() {
    #expect(
        AgentBarKeychainStore.serviceName(for: "com.agentbar.menu") ==
            AgentBarKeychainStore.productionService
    )
    #expect(
        AgentBarKeychainStore.serviceName(for: "com.agentbar.menu.widget") ==
            AgentBarKeychainStore.developmentService
    )
    #expect(
        AgentBarKeychainStore.serviceName(for: nil) ==
            AgentBarKeychainStore.developmentService
    )
}

@Test
func keychainStoreMigratesPreviousVaultsOnlyForProductionApp() {
    #expect(
        AgentBarKeychainStore.migrationServices(for: "com.agentbar.menu") == [
            AgentBarKeychainStore.previousProductionService,
            AgentBarKeychainStore.legacyService
        ]
    )
    #expect(AgentBarKeychainStore.migrationServices(for: "com.agentbar.menu.widget").isEmpty)
    #expect(AgentBarKeychainStore.migrationServices(for: nil).isEmpty)
}
