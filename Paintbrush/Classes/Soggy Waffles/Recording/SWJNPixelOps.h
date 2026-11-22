//
//  SWJNPixelOps.h
//  Paintbrush
//
//  Hot pixel loops for the drawing recorder, kept in C so they stay fast in
//  debug builds. Pixels are 8 bit RGBA, premultiplied, one row after another
//  in bitmap data order (row 0 is the bottom of the picture on screen).
//

#ifndef SWJNPixelOps_h
#define SWJNPixelOps_h

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Composites `buffer` over `main` for the rect (x, y, w, h) in main's data
/// coordinates and writes the result to `dst`, packed at w * 4 bytes per row.
/// Buffer row r lines up with main row r + bufferRowOffset; pass a NULL buffer
/// to copy main alone.
void SWJNCompositeRect(const uint8_t *main, size_t mainRowBytes,
                       const uint8_t *buffer, size_t bufferRowBytes,
                       int bufferWidth, int bufferHeight, int bufferRowOffset,
                       int x, int y, int w, int h, uint8_t *dst);

/// Compares `region` (packed, w * h) with the same rect of `canvas` (packed,
/// canvasWidth pixels per row) placed at (x, y). Returns 1 and the bounding box
/// of the changed pixels, relative to the region, or 0 when nothing changed.
int SWJNDiffBounds(const uint8_t *region, int w, int h,
                   const uint8_t *canvas, int canvasWidth, int x, int y,
                   int *outX, int *outY, int *outW, int *outH);

/// Copies a w * h block of pixels between two buffers.
void SWJNCopyPixels(const uint8_t *src, size_t srcRowBytes, int srcX, int srcY,
                    uint8_t *dst, size_t dstRowBytes, int dstX, int dstY,
                    int w, int h);

#ifdef __cplusplus
}
#endif

#endif
