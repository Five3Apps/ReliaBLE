import Testing
@testable import ReliaBLE

@Test func correctFunction() async throws {
    // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    let package = ReliaBLEManager()
    #expect(package.testFunction() == "Hello, this is ReliaBLE!", "Incorrect response string")
}
