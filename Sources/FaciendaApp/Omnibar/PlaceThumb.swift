import SwiftUI
import FaciendaCore

/// Where a task lives, as pictures: its group's cover with its workspace's planet on the corner, or the workspace's
/// picture alone when it has no group or the group has no cover. The planet is ringed in blue for another workspace than
/// the one open. The bar's results and History draw tasks the same way.
struct PlaceThumb: View {
    let place: BarPlace?
    let workspaces: WorkspaceController?
    let elsewhere: Bool
    var size = CGSize(width: 64, height: 40)

    var body: some View {
        let dot = (size.height * 0.55).rounded(), corner = (size.height * 0.175).rounded()
        let planet = place.flatMap { workspaces?.coverImages[$0.workspaceID] }
        let cover = place?.groupID.flatMap { workspaces?.groupCover($0) }
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = cover ?? planet { Image(nsImage: image).resizable().scaledToFill() }
                else { initial.background(Palette.sidebar) }
            }
            .frame(width: size.width, height: size.height).clipShape(RoundedRectangle(cornerRadius: corner))
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(Palette.ink.opacity(0.08), lineWidth: 1))
            if cover != nil {
                Group {
                    if let planet { Image(nsImage: planet).resizable().scaledToFill() } else { initial.background(Palette.sidebar) }
                }
                .frame(width: dot, height: dot).clipShape(Circle())
                .overlay(Circle().strokeBorder(elsewhere ? Palette.blue : Palette.card, lineWidth: elsewhere ? 2 : 1.5))
                .offset(x: -5, y: 5)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            // Without a planet on a cover, another workspace is ringed on the picture itself.
            if cover == nil && elsewhere { RoundedRectangle(cornerRadius: corner).strokeBorder(Palette.blue, lineWidth: 1.5) }
        }
        .accessibilityHidden(true)
    }

    private var initial: some View {
        Text((place?.workspaceName.prefix(1) ?? "").uppercased())
            .font(.system(size: 14, design: .serif)).foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
