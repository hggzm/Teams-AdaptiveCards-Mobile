package io.adaptivecards.snapshottests

/**
 * Marker class for the snapshot tests module.
 *
 * This module contains Paparazzi-based visual regression tests that verify
 * the rendering of Adaptive Card components. Tests run on the JVM without
 * an emulator, using Android's layoutlib for rendering.
 *
 * ## Usage
 *
 * ```bash
 * # Record new baselines (run after intentional visual changes):
 * ./gradlew :snapshottests:recordPaparazziDebug
 *
 * # Verify against baselines (run in CI or before committing):
 * ./gradlew :snapshottests:verifyPaparazziDebug
 * ```
 *
 * ## What's tested
 *
 * - Accessibility overlays (roleDescription, live regions, a11y delegates)
 * - Component rendering (ProgressBar, ImageView, RadioGroup, Buttons)
 * - Dark/light mode appearance
 * - Error state rendering
 */
object SnapshotTestModule {
    const val VERSION = "1.0.0"
}
