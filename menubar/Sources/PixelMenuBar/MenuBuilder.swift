import AppKit
import PixelMenuBarCore

/// The dropdown: one row per session, then pet choice, hook status, Quit.
@MainActor
final class MenuBuilder {
    let renderer: LaneRenderer
    let choice: () -> PetChoice
    let setChoice: (PetChoice) -> Void
    let laneSetting: () -> LaneSetting
    let target: AnyObject
    let openFolderAction: Selector
    let quitAction: Selector
    let pickPetAction: Selector
    let pickLaneAction: Selector

    init(renderer: LaneRenderer, choice: @escaping () -> PetChoice, setChoice: @escaping (PetChoice) -> Void,
         laneSetting: @escaping () -> LaneSetting,
         target: AnyObject, openFolderAction: Selector, quitAction: Selector, pickPetAction: Selector,
         pickLaneAction: Selector) {
        self.renderer = renderer
        self.choice = choice
        self.setChoice = setChoice
        self.laneSetting = laneSetting
        self.target = target
        self.openFolderAction = openFolderAction
        self.quitAction = quitAction
        self.pickPetAction = pickPetAction
        self.pickLaneAction = pickLaneAction
    }

    func rebuild(_ menu: NSMenu, agents: [Agent], laneCap: Double?) {
        menu.removeAllItems()

        let header = NSMenuItem(title: agents.isEmpty ? "No active Claude sessions" : "\(agents.count) Claude session\(agents.count == 1 ? "" : "s")", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for agent in agents {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.attributedTitle = Self.rowTitle(agent)
            if let idle = renderer.petFor(agentId: agent.id, choice: choice())?.idle.first {
                // Menu icons sit in a ~16pt slot; the idle pose is already that size.
                item.image = NSImage(cgImage: idle.image, size: NSSize(width: idle.width, height: idle.height))
            }
            item.toolTip = agent.cwd
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let petItem = NSMenuItem(title: "Pet", action: nil, keyEquivalent: "")
        let petMenu = NSMenu()
        let options: [(String, PetChoice)] = [("Mixed", .mixed)] + renderer.pets.map { ($0.name.capitalized, .named($0.name)) }
        for (title, option) in options {
            let entry = NSMenuItem(title: title, action: pickPetAction, keyEquivalent: "")
            entry.target = target
            entry.representedObject = option.stored
            entry.state = option == choice() ? .on : .off
            petMenu.addItem(entry)
        }
        petItem.submenu = petMenu
        menu.addItem(petItem)

        let laneItem = NSMenuItem(title: "Lane width", action: nil, keyEquivalent: "")
        let laneMenu = NSMenu()
        for option in LaneSetting.presets {
            var title = option.title
            // Say so when this screen cannot show the full width, instead of silently ignoring the choice.
            if let laneCap, case let .fixed(width) = option, width > laneCap {
                title += " (fits \(Int(laneCap)))"
            }
            let entry = NSMenuItem(title: title, action: pickLaneAction, keyEquivalent: "")
            entry.target = target
            entry.representedObject = NSNumber(value: option.stored)
            entry.state = option == laneSetting() ? .on : .off
            laneMenu.addItem(entry)
        }
        laneItem.submenu = laneMenu
        menu.addItem(laneItem)

        let hooks = NSMenuItem(title: HooksStatus.summary(), action: nil, keyEquivalent: "")
        hooks.isEnabled = false
        menu.addItem(hooks)

        let open = NSMenuItem(title: "Open ~/.pixel-agents", action: openFolderAction, keyEquivalent: "")
        open.target = target
        menu.addItem(open)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Pixel Agents Menu Bar", action: quitAction, keyEquivalent: "q")
        quit.target = target
        menu.addItem(quit)
    }

    static func rowTitle(_ agent: Agent) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let out = NSMutableAttributedString(
            string: agent.project,
            attributes: [.font: NSFont.systemFont(ofSize: font.pointSize, weight: .medium)]
        )
        let stateColor: NSColor = agent.state == .permission ? .systemOrange : .secondaryLabelColor
        out.append(NSAttributedString(string: "  \u{00B7}  \(agent.state.title)", attributes: [.font: font, .foregroundColor: stateColor]))
        if !agent.label.isEmpty {
            out.append(NSAttributedString(string: "  \u{00B7}  \(agent.label)", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        if agent.subagents > 0 {
            out.append(NSAttributedString(string: "  (+\(agent.subagents) subagent\(agent.subagents == 1 ? "" : "s"))", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return out
    }
}
