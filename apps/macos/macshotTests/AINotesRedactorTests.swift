import XCTest

/// Secrets must not reach AI notes; ordinary text must reach them intact.
final class AINotesRedactorTests: XCTestCase {

    // Made-up keys in the shapes real ones have. They are assembled from pieces so that secret
    // scanners reading this repository do not mistake the fixtures for leaked credentials.
    private static let stripeKey = ["sk", "live", "51H8xQ2LkJhGfDsAzXcVbNmQwErTy"].joined(separator: "_")

    func testRecognisableSecretsAreRedactedInPlace() {
        let secrets = [
            "sk-" + "ant-api03-AbCdEf0123456789AbCdEf0123456789",
            Self.stripeKey,
            "ghp" + "_abcdefghijklmnopqrstuvwxyz0123456789",
            "github" + "_pat_11ABCDEFG0123456789_abcdefghij",
            "xox" + "b-123456789012-abcdefghijkl",
            "AKIA" + "IOSFODNN7EXAMPLE",
            "AIza" + "SyA1234567890abcdefghijklmnopqrstuv",
            "eyJ" + "hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N",
            "d41d8cd98f00b204e9800998ecf8427e",
            "4242 4242 4242 4242",
            "4111-1111-1111-1111",
            "378282246310005",
            "aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bD1fH3jL5nP7rT9vX1zB3",
        ]
        for secret in secrets {
            let result = AINotesRedactor.redact("Before \(secret) after")
            XCTAssertFalse(result.contains(secret), "left \(secret.prefix(14))… readable")
            XCTAssertTrue(result.contains(AINotesRedactor.mark))
            XCTAssertTrue(result.hasPrefix("Before ") && result.hasSuffix(" after"), "damaged the text around \(secret.prefix(14))…")
        }
    }

    func testLabelledValuesKeepTheirLabel() {
        XCTAssertEqual(AINotesRedactor.redact("password: hunter2!"), "password: [redacted]")
        XCTAssertEqual(AINotesRedactor.redact("API_KEY=abc123def"), "API_KEY=[redacted]")
        XCTAssertEqual(AINotesRedactor.redact("Authorization: Bearer abc.def-ghi_jkl123"), "Authorization: Bearer [redacted]")
        XCTAssertEqual(AINotesRedactor.redact(#"{"client_secret": "s3cr3tvalue"}"#), #"{"client_secret": "[redacted]"}"#)
        XCTAssertEqual(AINotesRedactor.redact("-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----"), AINotesRedactor.mark)
    }

    func testRecognisedTextLosesEverythingAfterASecretLabel() {
        // Text recognition often reads a long key with a space in it, which no token pattern survives.
        let split = "Secret key: " + Self.stripeKey.replacingOccurrences(of: "51H8", with: "51 H8")
        XCTAssertEqual(AINotesRedactor.redact(split, valuesRunToEndOfLine: true), "Secret key: [redacted]")
        XCTAssertEqual(AINotesRedactor.redact("Secret key: \(Self.stripeKey)", valuesRunToEndOfLine: true),
                       "Secret key: [redacted]")
        XCTAssertEqual(AINotesRedactor.redact("API key = abcd 1234 efgh\nPlace order", valuesRunToEndOfLine: true),
                       "API key = [redacted]\nPlace order", "the next line is not part of the value")
        XCTAssertEqual(AINotesRedactor.redact("Authorization: Bearer abc.def-ghi_jkl123 x", valuesRunToEndOfLine: true),
                       "Authorization: Bearer [redacted]")
        XCTAssertEqual(AINotesRedactor.redact("Place order", valuesRunToEndOfLine: true), "Place order")
        // Elsewhere (window titles, control names) only the value itself goes.
        XCTAssertEqual(AINotesRedactor.redact("secret_key=abcd1234 mode=test"), "secret_key=[redacted] mode=test")
    }

    func testOrdinaryTextIsLeftAlone() {
        let harmless = [
            "Place order", "Order #1234567890 was placed on 2026-11-10", "Call 555 010 9999 today",
            "Checkout – Example Store", "Error: payment gateway timeout (504)", "Total $1,234.56",
            "1234567890123", "Forgot your password?", "Token expired, sign in again",
            "https://example.com/checkout?step=2", "Version 0.2.2 (1) build 4f3a9c1",
            "Height 9.5 cm, 2024 to 2027", "amy@example.com", "192.168.1.20", "",
        ]
        for text in harmless {
            XCTAssertEqual(AINotesRedactor.redact(text), text)
        }
    }

    func testCardNumbers() {
        XCTAssertTrue(AINotesRedactor.luhn("4242424242424242"))
        XCTAssertFalse(AINotesRedactor.luhn("1234567890123456"))
        XCTAssertFalse(AINotesRedactor.redact("Card number 4242 4242 4242 42").contains("4242"),
                       "a card number still being typed fails the checksum but must go anyway")
    }

    func testChangedSpanCoversOnlyWhatWasReplaced() throws {
        let original = "Secret key: \(Self.stripeKey) (test)"
        let redacted = AINotesRedactor.redact(original)
        let span = try XCTUnwrap(AINotesRedactor.changedSpan(original: original, redacted: redacted))
        XCTAssertEqual(String(Array(original)[span]), Self.stripeKey, "the label stays out of the blackout")
        XCTAssertNil(AINotesRedactor.changedSpan(original: "Place order", redacted: "Place order"))
        let whole = try XCTUnwrap(AINotesRedactor.changedSpan(original: "AKIA" + "IOSFODNN7EXAMPLE", redacted: AINotesRedactor.mark))
        XCTAssertEqual(whole, 0..<20)
    }
}
