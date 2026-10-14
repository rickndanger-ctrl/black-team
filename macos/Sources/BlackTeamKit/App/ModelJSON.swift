import Foundation

/// A saved model as the configuration file holds it (the same encoding the model list uses).
func modelJSON(_ model: ModelConfig) -> JSONValue {
    let data = (try? JSONEncoder().encode(model)) ?? Data("{}".utf8)
    return (try? JSONValue.parse(data)) ?? .object([:])
}
