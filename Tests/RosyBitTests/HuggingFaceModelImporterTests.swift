import XCTest
@testable import RosyBit

final class HuggingFaceModelImporterTests: XCTestCase {
    func testParsesRepositoryIdentifier() {
        XCTAssertEqual(
            HuggingFaceModelImporter.Source.parse("Qwen/Qwen3.5-0.8B"),
            .init(repository: "Qwen/Qwen3.5-0.8B", exactFile: nil, revision: "main")
        )
    }

    func testParsesRepositoryURL() {
        XCTAssertEqual(
            HuggingFaceModelImporter.Source.parse("https://huggingface.co/Qwen/Qwen3.5-0.8B"),
            .init(repository: "Qwen/Qwen3.5-0.8B", exactFile: nil, revision: "main")
        )
    }

    func testParsesDirectBlobAndResolveLinks() {
        for verb in ["blob", "resolve"] {
            XCTAssertEqual(
                HuggingFaceModelImporter.Source.parse(
                    "https://huggingface.co/org/model/\(verb)/main/quant/model-Q4_K_M.gguf?download=true"
                ),
                .init(repository: "org/model", exactFile: "quant/model-Q4_K_M.gguf", revision: "main")
            )
        }
    }

    func testDirectLinkPreservesItsRevision() {
        XCTAssertEqual(
            HuggingFaceModelImporter.Source.parse(
                "https://huggingface.co/org/model/resolve/v2/quant/model.gguf"
            ),
            .init(repository: "org/model", exactFile: "quant/model.gguf", revision: "v2")
        )
    }

    func testRejectsOtherHostsAndMalformedIdentifiers() {
        XCTAssertNil(HuggingFaceModelImporter.Source.parse("https://example.com/org/model"))
        XCTAssertNil(HuggingFaceModelImporter.Source.parse("one-segment"))
        XCTAssertNil(HuggingFaceModelImporter.Source.parse("org/../model"))
    }
}
