package com.safeguard.app.ai

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.safeguard.app.engine.ai.ClassificationError
import com.safeguard.app.engine.ai.image.DecodedImage
import com.safeguard.app.engine.ai.image.ImageDecoder
import com.safeguard.app.engine.ai.image.ImageHeader
import com.safeguard.app.engine.ai.image.ImageRejectedException

/**
 * Android decoder for the image pipeline. The header was already validated;
 * this decodes subsampled (never the full-resolution image), checks that
 * the platform agrees with the header, and recycles the bitmap on close.
 */
class BitmapImageDecoder : ImageDecoder {

    override fun decode(bytes: ByteArray, header: ImageHeader, sampleSize: Int): DecodedImage {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth != header.width || bounds.outHeight != header.height) {
            throw ImageRejectedException(ClassificationError.MALFORMED)
        }
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inMutable = false
        }
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
            ?: throw ImageRejectedException(ClassificationError.DECODE_FAILED)
        return BitmapImage(bitmap)
    }

    private class BitmapImage(private var bitmap: Bitmap?) : DecodedImage {
        override val width: Int = bitmap!!.width
        override val height: Int = bitmap!!.height
        override val pixels: IntArray = IntArray(width * height).also {
            bitmap!!.getPixels(it, 0, width, 0, 0, width, height)
        }

        override fun close() {
            pixels.fill(0)
            bitmap?.recycle()
            bitmap = null
        }
    }
}
