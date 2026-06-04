import XCTest
import AppKit
@testable import ParleqAppCore

/// Pins each computed `OverlayLayoutMetrics` constant to its documented
/// design value at standard system metrics.  A ±2 pt tolerance lets the
/// tests survive minor floating-point rounding differences across macOS
/// versions without masking a real drift — if a future system-font change
/// shifts a constant by more than 2 pt the failure is intentional and the
/// developer should update the constant and the design documentation.
final class OverlayLayoutMetricsTests: XCTestCase {

    // MARK: - contentWellMinHeight

    /// Documented design value: 46 pt.
    ///   = (idleMax 14 + levelBoost 14) × scale 1.5 + 2 × padding 2
    ///   = 42 + 4 = 46 pt
    func test_contentWellMinHeight_near_46() {
        let value = OverlayLayoutMetrics.contentWellMinHeight
        XCTAssertEqual(value, 46, accuracy: 2,
            "contentWellMinHeight should be ~46 pt (listening indicator peak + padding)")
    }

    /// The value must be positive and large enough to hold a listening icon.
    func test_contentWellMinHeight_is_positive_and_reasonable() {
        let value = OverlayLayoutMetrics.contentWellMinHeight
        XCTAssertGreaterThan(value, 0)
        XCTAssertGreaterThan(value, 20,
            "contentWellMinHeight must be tall enough to hold a visible icon")
    }

    // MARK: - utilitySlotHeight

    /// Documented design value: 26 pt.
    ///   = ceil(ascender − descender + leading) for 11 pt system font
    ///     + 2 × 6 pt vertical padding
    ///   ≈ 14 + 12 = 26 pt
    func test_utilitySlotHeight_near_26() {
        let value = OverlayLayoutMetrics.utilitySlotHeight
        XCTAssertEqual(value, 26, accuracy: 2,
            "utilitySlotHeight should be ~26 pt (11 pt font line height + 2 × 6 pt padding)")
    }

    /// The value must be strictly larger than a bare text line height at 11 pt
    /// (the slot holds a padded hint strip, not a bare label).
    func test_utilitySlotHeight_exceeds_bare_font_line_height() {
        let font = NSFont.systemFont(ofSize: 11)
        let bareLineHeight = ceil(font.ascender - font.descender + font.leading)
        XCTAssertGreaterThan(OverlayLayoutMetrics.utilitySlotHeight, bareLineHeight,
            "utilitySlotHeight must include vertical padding above bare font line height")
    }

    // MARK: - footerRow1MinHeight

    /// Documented design value: 24 pt.
    ///   = ceil(ascender − descender + leading) for small-control font
    ///     + 2 × 4 pt button inset + 2 pt breathing room
    ///   ≈ 14 + 8 + 2 = 24 pt
    func test_footerRow1MinHeight_near_24() {
        let value = OverlayLayoutMetrics.footerRow1MinHeight
        XCTAssertEqual(value, 24, accuracy: 2,
            "footerRow1MinHeight should be ~24 pt (small button height + breathing room)")
    }

    /// The value must clear the small-button's empirical height (~22 pt).
    func test_footerRow1MinHeight_clears_small_button_height() {
        // Approximate the small-button height: font line + 2 × inset.
        let f = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        let approxButtonHeight = ceil(f.ascender - f.descender + f.leading) + 8
        XCTAssertGreaterThanOrEqual(OverlayLayoutMetrics.footerRow1MinHeight, approxButtonHeight,
            "footerRow1MinHeight must be at least as tall as a .small bordered button")
    }

    // MARK: - wellMinHeight

    /// Documented design value: ~66 pt.
    ///   = contentWellMinHeight (46) + vstackSpacing (6) + statusLineHeight (≈14)
    ///   ≈ 46 + 6 + 14 = 66 pt
    func test_wellMinHeight_near_66() {
        let value = OverlayLayoutMetrics.wellMinHeight
        XCTAssertEqual(value, 66, accuracy: 2,
            "wellMinHeight should be ~66 pt (contentWellMinHeight + spacing + status line)")
    }

    /// wellMinHeight must be strictly larger than contentWellMinHeight,
    /// since it adds the VStack spacing and the status line on top.
    func test_wellMinHeight_exceeds_contentWellMinHeight() {
        XCTAssertGreaterThan(OverlayLayoutMetrics.wellMinHeight,
                             OverlayLayoutMetrics.contentWellMinHeight,
            "wellMinHeight must exceed contentWellMinHeight by at least the status line height")
    }
}
