/*
 * R1 standalone ABI smoke test.
 *
 * Compiles and runs without linking RetouchStudio, Swift, AppKit, Core Image,
 * Vision, or any engine implementation. It validates only the header's
 * declarations, constants, and fixed-width field types.
 */

#include "studioscore_image_engine.h"

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#define TYPE_IS(expr, type) _Generic((expr), type: 1, default: 0)

_Static_assert(SC_IMAGE_ENGINE_ABI == 1u, "ABI version changed");
_Static_assert(SC_IMAGE_ENGINE_ABI_MIN == 1u, "minimum ABI version changed");

_Static_assert(SC_STATUS_OK == 0, "OK must be zero");
_Static_assert(SC_STATUS_INVALID_ARGUMENT == 1, "status numbering changed");
_Static_assert(SC_STATUS_VALIDATION_FAILED == 12, "status numbering changed");
_Static_assert(SC_STATUS_CANCELLED == 13, "status numbering changed");
_Static_assert(SC_STATUS_INTERNAL == 19, "status numbering changed");

_Static_assert(SC_PIXEL_RGBA8_PREMULTIPLIED == 1, "pixel format changed");
_Static_assert(SC_PIXEL_GRAY8 == 4, "pixel format changed");
_Static_assert(SC_COLOR_SRGB == 1, "colour encoding changed");
_Static_assert(SC_COLOR_ICC == 4, "colour encoding changed");
_Static_assert(SC_TARGET_PREVIEW == 1, "target kind changed");
_Static_assert(SC_TARGET_EXPORT == 2, "target kind changed");

_Static_assert(sizeof(ScStatus) == 4, "ScStatus must be 32-bit");
_Static_assert(sizeof(ScPixelFormat) == 4, "ScPixelFormat must be 32-bit");
_Static_assert(sizeof(ScColorEncoding) == 4, "ScColorEncoding must be 32-bit");
_Static_assert(sizeof(ScTargetKind) == 4, "ScTargetKind must be 32-bit");

_Static_assert(offsetof(ScImageBuffer, struct_size) == 0,
               "struct_size must be first");
_Static_assert(offsetof(ScImageBuffer, abi_version) == sizeof(uint32_t),
               "abi_version must follow struct_size");
_Static_assert(TYPE_IS(((ScImageBuffer *)0)->width, uint32_t),
               "width must be uint32_t");
_Static_assert(TYPE_IS(((ScImageBuffer *)0)->height, uint32_t),
               "height must be uint32_t");
_Static_assert(TYPE_IS(((ScImageBuffer *)0)->bytes_per_row, uint32_t),
               "bytes_per_row must be uint32_t");
_Static_assert(TYPE_IS(((ScRenderTarget *)0)->max_long_edge, uint32_t),
               "max_long_edge must be uint32_t");
_Static_assert(TYPE_IS(((ScRenderTarget *)0)->scale, double),
               "scale must be double");
_Static_assert(TYPE_IS(((ScProgress *)0)->units_done, uint64_t),
               "units_done must be uint64_t");
_Static_assert(TYPE_IS(((ScProgress *)0)->fraction, double),
               "fraction must be double");
_Static_assert(TYPE_IS(((ScError *)0)->code, int32_t),
               "error code must be int32_t");

_Static_assert(
    _Generic(&sc_engine_create,
             ScStatus (*)(uint32_t, ScEngine **, ScError **): 1, default: 0),
    "sc_engine_create signature changed");
_Static_assert(
    _Generic(&sc_engine_render,
             ScStatus (*)(ScEngine *, const ScRenderRequest *, ScImageBuffer *,
                          ScError **): 1,
             default: 0),
    "sc_engine_render signature changed");
_Static_assert(
    _Generic(&sc_engine_destroy, void (*)(ScEngine *): 1, default: 0),
    "sc_engine_destroy signature changed");

int main(void) {
  printf("studioscore abi=%u status_count=%d error_codes=%d\n",
         SC_IMAGE_ENGINE_ABI, 20, SC_STATUS_INTERNAL + 1);
  return 0;
}
