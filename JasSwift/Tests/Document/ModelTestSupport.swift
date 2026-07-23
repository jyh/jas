@testable import JasLib

/// Test-fixture seeding write — the Swift mirror of Rust's `#[cfg(test)]`
/// `set_document_for_test` (Arc 1 S1). Lives in the TEST TARGET only, so
/// production code can never route a write through the `.testOnly` intent:
/// the seclusion is compile-time, playing the role of the Rust twin's
/// `debug_assert!(cfg!(test))` teeth. Every test-file document-seeding site
/// calls this instead of `setDocumentUnbracketed(_:intent:)` directly, so
/// test setup carries no intent churn.
extension Model {
    func setDocumentForTest(_ doc: Document) {
        setDocumentUnbracketed(doc, intent: .testOnly)
    }
}
