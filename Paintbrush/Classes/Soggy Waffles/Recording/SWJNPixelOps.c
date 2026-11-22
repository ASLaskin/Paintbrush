//
//  SWJNPixelOps.c
//  Paintbrush
//

#include "SWJNPixelOps.h"
#include <string.h>

// True when `length` bytes are all zero (a fully transparent run of the buffer)
static int SWJNIsClear(const uint8_t *bytes, size_t length)
{
    static const uint8_t zeros[4096] = {0};
    while (length > 0) {
        size_t chunk = length < sizeof(zeros) ? length : sizeof(zeros);
        if (memcmp(bytes, zeros, chunk) != 0)
            return 0;
        bytes += chunk;
        length -= chunk;
    }
    return 1;
}

void SWJNCompositeRect(const uint8_t *main, size_t mainRowBytes,
                       const uint8_t *buffer, size_t bufferRowBytes,
                       int bufferWidth, int bufferHeight, int bufferRowOffset,
                       int x, int y, int w, int h, uint8_t *dst)
{
    size_t dstRowBytes = (size_t)w * 4;
    for (int row = 0; row < h; row++) {
        const uint8_t *m = main + (size_t)(y + row) * mainRowBytes + (size_t)x * 4;
        uint8_t *d = dst + (size_t)row * dstRowBytes;
        memcpy(d, m, dstRowBytes);

        int bufferRow = y + row - bufferRowOffset;
        if (!buffer || bufferRow < 0 || bufferRow >= bufferHeight)
            continue;

        int end = x + w < bufferWidth ? x + w : bufferWidth;
        if (end <= x)
            continue;
        const uint8_t *b = buffer + (size_t)bufferRow * bufferRowBytes;
        // Most of the buffer is empty most of the time
        if (SWJNIsClear(b + (size_t)x * 4, (size_t)(end - x) * 4))
            continue;

        int col = x;
        while (col < end) {
            unsigned sa = b[(size_t)col * 4 + 3];
            if (sa == 0) {
                col++;
                continue;
            }
            if (sa == 255) {
                // Copy a whole run of opaque pixels at once
                int run = col + 1;
                while (run < end && b[(size_t)run * 4 + 3] == 255) run++;
                memcpy(d + (size_t)(col - x) * 4, b + (size_t)col * 4, (size_t)(run - col) * 4);
                col = run;
                continue;
            }
            // Source over, premultiplied
            const uint8_t *src = b + (size_t)col * 4;
            uint8_t *p = d + (size_t)(col - x) * 4;
            unsigned inv = 255 - sa;
            for (int c = 0; c < 4; c++) {
                unsigned v = src[c] + (p[c] * inv + 127) / 255;
                p[c] = (uint8_t)(v > 255 ? 255 : v);
            }
            col++;
        }
    }
}

int SWJNDiffBounds(const uint8_t *region, int w, int h,
                   const uint8_t *canvas, int canvasWidth, int x, int y,
                   int *outX, int *outY, int *outW, int *outH)
{
    size_t regionRowBytes = (size_t)w * 4;
    size_t canvasRowBytes = (size_t)canvasWidth * 4;
    int minX = w, minY = h, maxX = -1, maxY = -1;

    for (int row = 0; row < h; row++) {
        const uint32_t *a = (const uint32_t *)(region + (size_t)row * regionRowBytes);
        const uint32_t *b = (const uint32_t *)(canvas + (size_t)(y + row) * canvasRowBytes + (size_t)x * 4);
        if (memcmp(a, b, regionRowBytes) == 0)
            continue;

        int first = 0;
        while (a[first] == b[first]) first++;
        int last = w - 1;
        while (a[last] == b[last]) last--;

        if (first < minX) minX = first;
        if (last > maxX) maxX = last;
        if (row < minY) minY = row;
        maxY = row;
    }

    if (maxY < 0)
        return 0;
    *outX = minX;
    *outY = minY;
    *outW = maxX - minX + 1;
    *outH = maxY - minY + 1;
    return 1;
}

void SWJNCopyPixels(const uint8_t *src, size_t srcRowBytes, int srcX, int srcY,
                    uint8_t *dst, size_t dstRowBytes, int dstX, int dstY,
                    int w, int h)
{
    size_t rowLength = (size_t)w * 4;
    for (int row = 0; row < h; row++) {
        memcpy(dst + (size_t)(dstY + row) * dstRowBytes + (size_t)dstX * 4,
               src + (size_t)(srcY + row) * srcRowBytes + (size_t)srcX * 4,
               rowLength);
    }
}
