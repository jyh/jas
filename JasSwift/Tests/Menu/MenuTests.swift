import Testing
@testable import JasLib

@Test func jasCommandsInitializes() {
    let commands = JasCommands()
    #expect(commands != nil)
}
