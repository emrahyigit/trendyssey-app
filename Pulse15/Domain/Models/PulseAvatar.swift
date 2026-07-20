import SwiftUI

struct PulseAvatar: Identifiable, Hashable, Sendable {
    let id: String
    let assetName: String

    static let all: [PulseAvatar] = [
        .init(id: "orbit", assetName: "AvatarGamer"),
        .init(id: "nova", assetName: "AvatarDoctor"),
        .init(id: "flare", assetName: "AvatarPilot"),
        .init(id: "wave", assetName: "AvatarRanger"),
        .init(id: "prism", assetName: "AvatarDesigner"),
        .init(id: "void", assetName: "AvatarAnalyst"),
        .init(id: "builder", assetName: "AvatarBuilder"),
        .init(id: "medic", assetName: "AvatarMedic"),
        .init(id: "reporter", assetName: "AvatarReporter"),
        .init(id: "operator", assetName: "AvatarOperator"),
        .init(id: "chef", assetName: "AvatarChef"),
        .init(id: "pharmacist", assetName: "AvatarPharmacist"),
    ]

    static func value(for key: String) -> PulseAvatar { all.first { $0.id == key } ?? all[0] }
}

struct PulseAvatarView: View {
    let key: String
    var size: CGFloat = 40

    var body: some View {
        let avatar = PulseAvatar.value(for: key)
        Image(avatar.assetName)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .scaleEffect(1.08)
            .offset(y: size * 0.03)
            .clipShape(Circle())
            .overlay { Circle().stroke(.white.opacity(0.32), lineWidth: 1) }
            .shadow(color: .black.opacity(0.20), radius: size * 0.12, y: size * 0.05)
    }
}
