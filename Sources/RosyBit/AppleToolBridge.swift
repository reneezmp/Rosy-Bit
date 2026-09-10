import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Translates Rosy's OpenAI-shaped tool schemas into the ones FoundationModels
/// wants, so the on-device model can call the same skills every other runtime
/// calls.
///
/// The two systems describe tools differently rather than incompatibly.
/// OpenAI-style providers take JSON Schema over the wire; FoundationModels
/// takes a Swift `Tool` whose parameters are a `GenerationSchema`. The obvious
/// reading is that every skill needs a hand-written `@Generable` type, which is
/// why this looked like a rewrite at first. It is not: `DynamicGenerationSchema`
/// builds the same thing at runtime, so one translator serves all nine skills
/// and any that come later.
///
/// **Nothing here validates arguments.** It converts a description of a tool,
/// and hands the model's answer back as the same JSON string an HTTP provider
/// would have sent. Every argument still goes through the skill's own native
/// parser and bounds check before anything happens — which is the whole reason
/// the observation is produced by a closure this file knows nothing about.
@available(macOS 26.0, *)
enum AppleToolBridge {

    enum BridgeError: LocalizedError {
        case unsupportedType(tool: String, property: String, type: String)
        case malformed(tool: String)

        var errorDescription: String? {
            switch self {
            case .unsupportedType(let tool, let property, let type):
                return "Rosy cannot describe \(tool)'s \"\(property)\" parameter to "
                    + "Apple's model: the type \"\(type)\" has no equivalent."
            case .malformed(let tool):
                return "Rosy could not read the schema for \(tool)."
            }
        }
    }

    /// One skill, wearing FoundationModels' shape.
    ///
    /// `Arguments` is `GeneratedContent` rather than a generated Swift type
    /// precisely so this stays generic: the model's answer is turned straight
    /// back into JSON and handed to the skill's existing parser, which is the
    /// one that decides whether it is acceptable.
    struct BridgedTool: FoundationModels.Tool {
        typealias Arguments = GeneratedContent
        typealias Output = String

        let name: String
        let description: String
        let parameters: GenerationSchema
        let invoke: @Sendable (String, String) async throws -> String

        func call(arguments: GeneratedContent) async throws -> String {
            try await invoke(name, arguments.jsonString)
        }
    }

    /// Every schema that can be translated, in the order given. One that cannot
    /// be is dropped rather than allowed to fail the whole request: a skill the
    /// model cannot see costs a retyped question, and a request that will not
    /// start costs the answer.
    static func tools(
        from schemas: [[String: Any]],
        invoke: @escaping @Sendable (String, String) async throws -> String
    ) -> [any FoundationModels.Tool] {
        schemas.compactMap { schema in
            guard let function = schema["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            let parameters = function["parameters"] as? [String: Any]
                ?? ["type": "object", "properties": [String: Any]()]
            guard let generation = try? generationSchema(name: name, parameters: parameters)
            else { return nil }
            return BridgedTool(
                name: name,
                // Same tool, same validators, wording tuned to this reader.
                // See `AppleToolDescriptions` for what that bought and why.
                description: AppleToolDescriptions.description(
                    for: name, shared: function["description"] as? String ?? ""),
                parameters: generation,
                invoke: invoke)
        }
    }

    static func generationSchema(
        name: String,
        parameters: [String: Any]
    ) throws -> GenerationSchema {
        try GenerationSchema(
            root: dynamicSchema(named: name, node: parameters, tool: name),
            dependencies: [])
    }

    /// Rosy's schemas use a deliberately small slice of JSON Schema — objects of
    /// strings, string enums, and bounded integers and numbers. Everything in
    /// that slice is translated exactly; anything outside it is refused loudly
    /// rather than approximated into something the model would then get wrong.
    static func dynamicSchema(
        named name: String,
        node: [String: Any],
        tool: String
    ) throws -> DynamicGenerationSchema {
        let description = node["description"] as? String

        switch node["type"] as? String {
        case "object", nil:
            let properties = node["properties"] as? [String: Any] ?? [:]
            let required = Set(node["required"] as? [String] ?? [])
            // Sorted so the schema handed to the model is byte-stable across
            // runs; Swift dictionaries are not ordered, and an unstable tool
            // block would defeat prefix reuse everywhere else in this app.
            let translated = try properties.keys.sorted().map { key -> DynamicGenerationSchema.Property in
                let child = properties[key] as? [String: Any] ?? [:]
                return DynamicGenerationSchema.Property(
                    name: key,
                    description: child["description"] as? String,
                    schema: try dynamicSchema(named: "\(name)_\(key)", node: child, tool: tool),
                    isOptional: !required.contains(key))
            }
            return DynamicGenerationSchema(
                name: name, description: description, properties: translated)

        case "string":
            if let choices = node["enum"] as? [String], !choices.isEmpty {
                return DynamicGenerationSchema(
                    name: name, description: description, anyOf: choices)
            }
            return DynamicGenerationSchema(type: String.self)

        case "integer":
            // The guide steers the model; it is not what keeps the value safe.
            // Rosy's own parser rejects anything out of bounds regardless, and
            // that check is the one that matters.
            var guides: [GenerationGuide<Int>] = []
            let lower = (node["minimum"] as? NSNumber)?.intValue
            let upper = (node["maximum"] as? NSNumber)?.intValue
            if let lower, let upper, lower <= upper {
                guides.append(.range(lower...upper))
            } else if let lower {
                guides.append(.minimum(lower))
            } else if let upper {
                guides.append(.maximum(upper))
            }
            return DynamicGenerationSchema(type: Int.self, guides: guides)

        case "number":
            var guides: [GenerationGuide<Double>] = []
            let lower = (node["minimum"] as? NSNumber)?.doubleValue
            let upper = (node["maximum"] as? NSNumber)?.doubleValue
            if let lower, let upper, lower <= upper {
                guides.append(.range(lower...upper))
            } else if let lower {
                guides.append(.minimum(lower))
            } else if let upper {
                guides.append(.maximum(upper))
            }
            return DynamicGenerationSchema(type: Double.self, guides: guides)

        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)

        case "array":
            let items = node["items"] as? [String: Any] ?? ["type": "string"]
            return DynamicGenerationSchema(
                arrayOf: try dynamicSchema(named: "\(name)_item", node: items, tool: tool))

        case .some(let other):
            throw BridgeError.unsupportedType(tool: tool, property: name, type: other)
        }
    }
}
#endif
