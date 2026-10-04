# Store captures

The listing is a draft for owner review. Nothing here uploads metadata or submits an App Store version.

The screenshot set uses the native app on dedicated iOS 18.3 simulators: iPhone 16 Pro Max and iPad Pro 13-inch. Account names and values are illustrative. Credentials and private account data are not used.

## Recreate the app screens

Run `scripts/capture-store-screenshots.sh <simulator-UUID> phone` or `scripts/capture-store-screenshots.sh <simulator-UUID> ipad` on a booted simulator whose name begins with `Requota Store`. Keep the device in portrait orientation. The script builds the app, removes the UI-test runner, sets the status bar, launches each screen and waits for each native PNG capture to complete.

`--store-screenshots --store-screen <tiles|bars|cards|charts|activity>` selects an initial screen in a Debug simulator build. It creates a separate `RequotaStoreCapture` metadata directory, uses no credentials, and skips network refreshes. It seeds six accounts for the phone overview, eight for the other phone screens, or thirteen for the tablet, with six favourites for the dense widget. These launch flags have no effect in Release builds.

Forty days of history include separate work schedules, weekends, idle periods and quota resets. Each counter increases within its quota cycle. The final readings match the dashboard. The ordinary demo in Settings uses the same improved history generator, with its own metadata and visible demo banner.

## Capture the phone Activity breakdown

The scripted phone Activity capture opens the monthly calendar. Keep a copy as `captures/iphone/05-calendar.png`, then tap an observed day and capture its native breakdown sheet as `captures/iphone/05-activity.png`. This revision selects 24 September with the medium sheet height. Verify that the selected date and account values are readable before rendering. The tablet displays the breakdown inline and needs no sheet.

## Capture the widget

On the dedicated phone simulator, launch the capture app, add the medium Requota Rows widget to the Home Screen and leave its default six favourites selected. Return to the Home Screen and verify that all six accounts have loaded. Remove any automation runner before capture.

Save the full native Home Screen to `captures/iphone/02-widgets.png` with `xcrun simctl io <UUID> screenshot <path>`. The artwork shows this original capture plus a close-up of the actual widget. The close-up coordinates are defined in `scripts/render-store-screenshots.swift`; update them if the widget moves.

## Render and review

Run `scripts/refresh-store-artwork.sh`. This produces opaque sRGB PNGs at 1320 × 2868 for iPhone and 2064 × 2752 for iPad, then regenerates `review.html`, the text fields and the validation manifest. `python3 scripts/prepare-store-listing.py --check` verifies the generated files, field limits, dimensions and PNG opacity.

Inspect every output image and its original capture. Check that each expected screen is visible, that text fits, and that the Home Screen contains no test runner. Dimensions and hashes cannot detect an incorrect screen.

## Validation for this revision

- Simulator app build succeeded.
- 16 selected DemoTests and UsageAnalysisTests passed with no failures.
- Tablet layouts checked in portrait and landscape; account grids adapt to width, chart height adapts to available height, and monthly activity has an inline day breakdown.
- Screenshot artwork and listing reviewed twice with Claude Opus 5.5 through the local CLI. The final review found no required corrections. Every image was visually inspected, and both galleries were checked in Chrome.

This screenshot set reflects the development branch rather than a numbered TestFlight build.
