// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
package io.adaptivecards.uitestapp

import android.graphics.Bitmap
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.screenshot.ScreenCapture
import androidx.test.runner.screenshot.ScreenCaptureProcessor
import java.io.*

class SaveScreenCaptureProcessor : ScreenCaptureProcessor {
    override fun process(capture: ScreenCapture?): String {
        val file: String = capture?.name ?: "Default.jpg"
        val data: ByteArray = getImageData(capture)

        // Use the app's internal files dir which is always writable
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val screenshotDir = File(context.filesDir, "screenshots")
        if (!screenshotDir.exists()) {
            screenshotDir.mkdirs()
        }

        val screenshotFile = File(screenshotDir, file)
        screenshotFile.createNewFile()

        val fos = FileOutputStream(screenshotFile)
        fos.write(data)
        fos.flush()
        fos.close()

        return screenshotDir.absolutePath
    }

    @Throws(IOException::class)
    private fun getImageData(capture: ScreenCapture?): ByteArray {
        val outputStream = ByteArrayOutputStream()
        capture!!.bitmap.compress(capture.format, 100, outputStream)
        return outputStream.toByteArray()
    }
}
