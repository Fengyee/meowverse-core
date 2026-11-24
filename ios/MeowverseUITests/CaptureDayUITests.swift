import XCTest

/// Capture days are shown and edited as calendar days, independent of the device's time zone.
final class CaptureDayUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Launches with the device in `zone`, stores one synthetic photo (EXIF day 2026-03-14) and
    /// opens its detail page. Returns the app and the page's date line.
    private func openSyntheticPhoto(store: String, zone: String) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = TestLanguage.chinese + ["-MeowverseStore", store, "-MeowverseResetStore", "-MeowverseSyntheticPhoto"]
        app.launchEnvironment["TZ"] = zone
        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 25))
        app.buttons["add-synthetic"].tap()
        let photoOnly = app.buttons["photo-only"]
        XCTAssertTrue(photoOnly.waitForExistence(timeout: 20))
        photoOnly.tap()
        let cell = app.buttons["library-photo"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        cell.tap()
        let dateLine = app.staticTexts["photo-date-line"]
        XCTAssertTrue(dateLine.waitForExistence(timeout: 10))
        return (app, dateLine)
    }

    /// The day the open editor's calendar shows as selected.
    private func selectedDay(_ picker: XCUIElement) -> XCUIElement {
        let selected = picker.descendants(matching: .button).matching(NSPredicate(format: "selected == true")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 6), picker.debugDescription)
        return selected
    }

    /// In the open editor, turns the month and year wheels to `year`/`month` and taps `day`
    /// (labels as the Chinese calendar shows them, e.g. "2011年", "12月", "12月30日").
    private func pick(year: String, month: String, day: String, in picker: XCUIElement) {
        // The header button switches the calendar to month and year wheels and back.
        let header = picker.buttons.matching(NSPredicate(format: "identifier IN %@", ["DatePicker.Show", "DatePicker.Hide"])).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 6), picker.debugDescription)
        header.tap()
        let wheels = picker.pickerWheels
        XCTAssertTrue(wheels.firstMatch.waitForExistence(timeout: 6), picker.debugDescription)
        let all = wheels.allElementsBoundByIndex
        let yearWheel = all.first { ($0.value as? String)?.contains("年") == true }
        let monthWheel = all.first { ($0.value as? String)?.contains("月") == true && ($0.value as? String)?.contains("年") != true }
        XCTAssertNotNil(yearWheel, picker.debugDescription)
        XCTAssertNotNil(monthWheel, picker.debugDescription)
        yearWheel?.adjust(toPickerWheelValue: year)
        monthWheel?.adjust(toPickerWheelValue: month)
        header.tap()
        let cell = picker.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", day)).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 6), picker.debugDescription)
        cell.tap()
    }

    private func waitForUserDay(_ dateLine: XCUIElement) {
        expectation(for: NSPredicate(format: "label CONTAINS %@", "你填写的"), evaluatedWith: dateLine)
        waitForExpectations(timeout: 10)
    }

    /// UTC+14, where 12:00 UTC is already the next local day: a picker that read the day in the
    /// device's zone would open on 15 March and save the day before the one tapped.
    func testDayEditorKeepsTheTappedDayInAFarEastZone() {
        let (app, dateLine) = openSyntheticPhoto(store: "capture-day-kiritimati", zone: "Pacific/Kiritimati")
        XCTAssertTrue(dateLine.label.contains("2026年3月14日"), dateLine.label)

        app.buttons["edit-date"].tap()
        let picker = app.datePickers.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 6))
        let selected = selectedDay(picker)
        XCTAssertTrue(selected.label.contains("3月14日"), "opens on the recorded day: \(selected.label)")
        let day = picker.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "3月10日")).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 6))
        day.tap()
        app.buttons["save-date"].tap()
        let edited = NSPredicate(format: "label CONTAINS %@", "2026年3月10日")
        expectation(for: edited, evaluatedWith: dateLine)
        waitForExpectations(timeout: 10)
    }

    /// Pacific/Apia skipped 2011-12-30: its local midnight does not exist, and reading the day at
    /// local midnight landed on the 31st. The day the user picked must be shown as that day.
    func testASkippedLocalDayIsShownAsItself() {
        let (app, dateLine) = openSyntheticPhoto(store: "capture-day-apia", zone: "Pacific/Apia")
        app.buttons["edit-date"].tap()
        let picker = app.datePickers.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 6))
        pick(year: "2011年", month: "12月", day: "12月30日", in: picker)
        app.buttons["save-date"].tap()
        waitForUserDay(dateLine)
        XCTAssertTrue(dateLine.label.contains("2011年12月30日"), dateLine.label)
    }

    /// Africa/Khartoum went from UTC+2 to UTC+3 at local noon on 2000-01-15, so that day has no
    /// 12:00. Reading days at local noon made it "no recorded date" and opened the editor on today.
    func testADayWithoutLocalNoonIsShownAndEditedAsItself() {
        let (app, dateLine) = openSyntheticPhoto(store: "capture-day-khartoum", zone: "Africa/Khartoum")
        app.buttons["edit-date"].tap()
        let picker = app.datePickers.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 6))
        pick(year: "2000年", month: "1月", day: "1月15日", in: picker)
        app.buttons["save-date"].tap()
        waitForUserDay(dateLine)
        XCTAssertTrue(dateLine.label.contains("2000年1月15日"), dateLine.label)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "没有记录拍摄日期")).firstMatch.exists,
                       "the day the user entered is a recorded day")

        app.buttons["edit-date"].tap()
        let reopened = app.datePickers.firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 6))
        let selected = selectedDay(reopened)
        XCTAssertTrue(selected.label.hasPrefix("1月15日"), "opens on the recorded day, not today: \(selected.label)")
        let header = reopened.buttons.matching(NSPredicate(format: "identifier == %@", "DatePicker.Show")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 6))
        XCTAssertTrue((header.value as? String)?.contains("2000年1月") == true, "shows January 2000: \(String(describing: header.value))")
    }
}
