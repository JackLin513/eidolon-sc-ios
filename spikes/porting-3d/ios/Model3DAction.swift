import EidolonCore

/// What the 3D renderer should play for one `StandDirection`.
struct Model3DAction: Equatable {
    enum Body: Equatable {
        case idle
        case talk
        case listen
        case nodYes
        case nodNo
        case end
    }

    let body: Body
    let mouthOpen: Bool
    let looking: Bool
    let mood: StandEmotion

    static let end = Model3DAction(body: .end, mouthOpen: false, looking: false, mood: .calm)
}

enum Model3DActionMap {
    static func action(for direction: StandDirection) -> Model3DAction {
        let body: Model3DAction.Body
        if let nod = direction.nod {
            body = nod.kind == .yes ? .nodYes : .nodNo
        } else if direction.speaking {
            body = .talk
        } else if direction.looking {
            body = .listen
        } else {
            body = .idle
        }
        return Model3DAction(
            body: body,
            mouthOpen: direction.speaking,
            looking: direction.looking,
            mood: direction.mood
        )
    }
}
