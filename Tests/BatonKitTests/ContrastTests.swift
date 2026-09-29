import Foundation
import Testing

@testable import BatonKit

@Suite("Contrast")
struct ContrastTests {
    @Test func ratiosMatchWCAG() {
        #expect(abs(Contrast.ratio("#000000", "#FFFFFF") - 21) < 0.01)
        #expect(abs(Contrast.ratio("#FFFFFF", "#FFFFFF") - 1) < 0.01)
        // The earlier palette's green and the system orange on white, as the review measured them.
        #expect(abs(Contrast.ratio("#2F9E44", "#FFFFFF") - 3.45) < 0.01)
        #expect(abs(Contrast.ratio("#FF9500", "#FFFFFF") - 2.20) < 0.01)
    }

    /// The badge in the window and the band of the Dock icon carry the label in white.
    @Test func everyBadgeColourCarriesWhiteText() {
        for color in Profile.palette + [Profile.mainColor] {
            #expect(Contrast.ratio(color, "#FFFFFF") >= Contrast.minimum, "\(color)")
        }
    }

    /// A profile made with the earlier palette keeps its colour; its badge is darkened just enough.
    @Test func earlierColoursAreDarkenedForTheBadge() {
        for old in ["#2F9E44", "#0C8599", "#E8590C", "#5C940D", "#D97757", "#FFFFFF", "#FFD43B"] {
            let badge = Contrast.behindWhiteText(old)
            #expect(Contrast.ratio(badge, "#FFFFFF") >= Contrast.minimum, "\(old) → \(badge)")
            #expect(Contrast.ratio(badge, "#FFFFFF") < Contrast.minimum + 0.3, "\(old) → \(badge): darker than needed")
        }
        #expect(Contrast.behindWhiteText("#1971C2") == "#1971C2")
        #expect(Contrast.behindWhiteText("#862e9c") == "#862E9C")
    }

    @Test func textColoursReachAAOnEveryBackground() {
        for (text, backgrounds) in [
            (TextColors.secondary.light, TextColors.backgrounds.light), (TextColors.warning.light, TextColors.backgrounds.light),
            (TextColors.secondary.dark, TextColors.backgrounds.dark), (TextColors.warning.dark, TextColors.backgrounds.dark),
        ] {
            for background in backgrounds {
                #expect(Contrast.ratio(text, background) >= Contrast.minimum, "\(text) on \(background)")
            }
        }
    }

    /// The details line and time of a Continue sheet row that is selected, in a focused list (blue) and in one that
    /// isn't (grey), in both appearances. The grey text alone was 1.15:1 on the blue.
    @Test func rowDetailsStayReadableOnASelectedRow() {
        let selected = TextColors.rowDetail(isSelected: true)
        let light = zip(TextColors.selectedRowText.light, TextColors.selectedRows.light).map { (selected?.light ?? $0, $1) }
        let dark = zip(TextColors.selectedRowText.dark, TextColors.selectedRows.dark).map { (selected?.dark ?? $0, $1) }
        for (text, row) in light + dark {
            #expect(Contrast.ratio(text, row) >= Contrast.minimum, "\(text) on \(row)")
        }
    }

    /// On the other rows they keep the secondary colour, 4.5:1 or more on every row background.
    @Test func rowDetailsAreSecondaryOnOtherRows() {
        #expect(TextColors.rowDetail(isSelected: false)?.light == TextColors.secondary.light)
        #expect(TextColors.rowDetail(isSelected: false)?.dark == TextColors.secondary.dark)
    }

    /// What the colours replace: black at 50% (the system's secondary text) and system orange on a light list row.
    @Test func systemColoursFallShortOnLightRows() {
        #expect(Contrast.ratio("#7C7C7C", "#F8F8F8") < Contrast.minimum)
        #expect(Contrast.ratio("#FF8D28", "#F8F8F8") < Contrast.minimum)
    }
}
