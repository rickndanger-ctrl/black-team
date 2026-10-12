import Foundation

// The thinking level, chosen with the reply length: one choice that trades time for care.
// Local servers that know these fields (llama.cpp with a thinking-capable model) honour them;
// others ignore unknown fields, so the request still works everywhere.
private let efforts: [String: String] = ["balanced": "medium", "deep": "high", "extended": "xhigh"]
private let budgets: [String: Double] = ["balanced": 512, "deep": 1024, "extended": 2048]

/// Fields to merge into a chat request for the given mode ("fast", "balanced", "deep", "extended").
/// Anything else thinks no more than fast.
public func thinkingOptions(_ mode: String = "balanced") -> [String: JSONValue] {
    let on = efforts[mode] != nil
    var options: [String: JSONValue] = [
        "reasoning_effort": .string(efforts[mode] ?? "none"),
        "chat_template_kwargs": ["enable_thinking": .bool(on), "preserve_thinking": true],
    ]
    if on { options["thinking_budget_tokens"] = .number(budgets[mode]!) }
    return options
}
