public struct InputEvent: Equatable {
    public let key: String
    public let payload: EventPayload?
    public init(key: String, payload: EventPayload? = nil) {
        self.key = key
        self.payload = payload
    }
}

public enum EventPayload: Equatable {
    case delta(dx: Double, dy: Double)
}
