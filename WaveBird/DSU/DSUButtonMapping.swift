enum DSUButtonMapping {
    static func applyingPositionMapping(to state: ControllerState) -> ControllerState {
        // The DSU spec doesn't define source-label mapping. WaveBird interprets
        // Y/B/A/X as north/east/south/west, using SDL's position convention;
        // Nintendo labels those positions X/A/B/Y.
        // This assumes Switch Pro/Joy-Con source positions; NSO GameCube's
        // different face-button layout is a known limitation and isn't handled.
        var mapped = state
        let buttons = state.buttons
        mapped.buttons.subtract([.a, .b, .x, .y])
        if buttons.contains(.a) { mapped.buttons.insert(.b) }
        if buttons.contains(.b) { mapped.buttons.insert(.a) }
        if buttons.contains(.x) { mapped.buttons.insert(.y) }
        if buttons.contains(.y) { mapped.buttons.insert(.x) }
        return mapped
    }
}
