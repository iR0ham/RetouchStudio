/*
 * StudioCore image-engine C ABI — R1 contract draft.
 *
 * Status: DRAFT. This header is not implemented and not production-ready.
 * It is compiled by the standalone R1 smoke test only.
 *
 * Ownership summary:
 *   - Input image bytes are host-owned and must stay valid until render returns.
 *   - Output image bytes are engine-owned until sc_buffer_release.
 *   - ScError is engine-owned until sc_error_release.
 *   - Strings are UTF-8; slices are not NUL-terminated unless stated.
 *
 * Versioning:
 *   - SC_IMAGE_ENGINE_ABI is the layout/behaviour version of this header.
 *   - Extensible structs begin with struct_size and abi_version. A caller may
 *     pass a smaller struct; the engine reads only the declared prefix.
 *   - Adding fields at the end is allowed within one ABI version. Renaming,
 *     removing, or changing a field requires a new ABI version.
 */

#ifndef STUDIOCORE_IMAGE_ENGINE_H
#define STUDIOCORE_IMAGE_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SC_IMAGE_ENGINE_ABI 1u
#define SC_IMAGE_ENGINE_ABI_MIN 1u

/* Fixed-width so the ABI does not depend on the compiler's enum size. */
typedef int32_t ScStatus;

enum {
  SC_STATUS_OK = 0,
  SC_STATUS_INVALID_ARGUMENT = 1,
  SC_STATUS_INVALID_STATE = 2,
  SC_STATUS_UNSUPPORTED_VERSION = 3,
  SC_STATUS_UNSUPPORTED_FEATURE = 4,
  SC_STATUS_DECODE_FAILED = 5,
  SC_STATUS_UNSUPPORTED_FORMAT = 6,
  SC_STATUS_SOURCE_MISSING = 7,
  SC_STATUS_SOURCE_CHANGED = 8,
  SC_STATUS_SOURCE_ACCESS_DENIED = 9,
  SC_STATUS_ASSET_MISSING = 10,
  SC_STATUS_ASSET_HASH_MISMATCH = 11,
  SC_STATUS_VALIDATION_FAILED = 12,
  SC_STATUS_CANCELLED = 13,
  SC_STATUS_BUSY = 14,
  SC_STATUS_ENGINE_FAILURE = 15,
  SC_STATUS_AI_UNAVAILABLE = 16,
  SC_STATUS_IO_FAILURE = 17,
  SC_STATUS_DURABILITY_FAILURE = 18,
  SC_STATUS_INTERNAL = 19
};

typedef struct ScEngine ScEngine;
typedef struct ScCancelToken ScCancelToken;

typedef struct ScSlice {
  const uint8_t *ptr;
  size_t len;
} ScSlice;

/*
 * A byte buffer with a producer-supplied release function.
 *
 * For engine outputs, release must be non-NULL. sc_buffer_release calls it
 * exactly once and then zeroes the descriptor.
 * For host inputs, release must be NULL. The engine never releases host memory.
 */
typedef void (*ScReleaseFn)(uint8_t *ptr, size_t len, void *user);

typedef struct ScOwnedBuffer {
  uint8_t *ptr;
  size_t len;
  ScReleaseFn release;
  void *user;
} ScOwnedBuffer;

typedef uint32_t ScPixelFormat;
enum {
  SC_PIXEL_RGBA8_PREMULTIPLIED = 1,
  SC_PIXEL_RGBA16 = 2,
  SC_PIXEL_RGBA16F = 3,
  SC_PIXEL_GRAY8 = 4
};

typedef uint32_t ScColorEncoding;
enum {
  SC_COLOR_SRGB = 1,
  SC_COLOR_DISPLAY_P3 = 2,
  SC_COLOR_ADOBE_RGB = 3,
  SC_COLOR_ICC = 4
};

typedef uint32_t ScTargetKind;
enum {
  SC_TARGET_PREVIEW = 1,
  SC_TARGET_EXPORT = 2
};

typedef struct ScImageBuffer {
  uint32_t struct_size;
  uint32_t abi_version;
  uint32_t width;
  uint32_t height;
  uint32_t bytes_per_row;
  ScPixelFormat format;
  ScColorEncoding color_encoding;
  ScSlice icc_profile; /* optional; required when encoding is SC_COLOR_ICC */
  ScOwnedBuffer pixels;
} ScImageBuffer;

/*
 * Stage index: 0 = decode, 1..17 = canonical engine stages, 18 = encode,
 * 19 = write. fraction is monotonic and advisory; a failed or cancelled job
 * may stop below 1.0.
 */
typedef struct ScProgress {
  uint32_t stage;
  uint32_t reserved;
  double fraction;
  uint64_t units_done;
  uint64_t units_total;
} ScProgress;

/*
 * Called on the render thread. It must return promptly and must not call back
 * into the same engine handle synchronously.
 */
typedef void (*ScProgressCallback)(const ScProgress *progress, void *user);

typedef struct ScRenderTarget {
  ScTargetKind kind;
  uint32_t max_long_edge; /* 0 = source size */
  double scale;           /* ignored when max_long_edge is non-zero */
} ScRenderTarget;

typedef struct ScRenderRequest {
  uint32_t struct_size;
  uint32_t abi_version;
  ScImageBuffer source;      /* host-owned input; pixels.release must be NULL */
  ScSlice render_plan_json;  /* canonical UTF-8 JSON */
  ScSlice mask_planes;       /* optional packed descriptors, see interface doc */
  ScCancelToken *cancel;     /* optional */
  ScProgressCallback progress;
  void *progress_user;
  ScRenderTarget target;
} ScRenderRequest;

/*
 * message_key is a NUL-terminated UTF-8 static string. detail_json and debug
 * are length-delimited UTF-8 owned by the error. The host must not free any
 * member separately; sc_error_release releases the whole error.
 */
typedef struct ScError {
  int32_t code;
  const char *message_key;
  ScOwnedBuffer detail_json;
  ScOwnedBuffer debug;
} ScError;

/*
 * All functions return SC_STATUS_OK on success. No C++ exception or foreign
 * unwind may cross this boundary. out_error may be NULL when the caller does
 * not want detail; otherwise it is set only on failure.
 */
ScStatus sc_engine_create(uint32_t abi_version,
                          ScEngine **out_engine,
                          ScError **out_error);

void sc_engine_destroy(ScEngine *engine);

ScStatus sc_engine_capabilities(ScEngine *engine,
                                ScOwnedBuffer *out_json,
                                ScError **out_error);

/*
 * Renders one immutable plan. On success out_image is zero-origin and owned by
 * the host until sc_buffer_release. On failure out_image is untouched.
 */
ScStatus sc_engine_render(ScEngine *engine,
                          const ScRenderRequest *request,
                          ScImageBuffer *out_image,
                          ScError **out_error);

ScStatus sc_engine_trim_cache(ScEngine *engine);

ScStatus sc_cancel_token_create(uint32_t abi_version,
                                ScCancelToken **out_token,
                                ScError **out_error);

void sc_cancel_token_destroy(ScCancelToken *token);

/*
 * Safe to call from a thread other than the render thread. The token is not
 * destroyed here; the host owns its lifetime.
 */
ScStatus sc_engine_cancel(ScEngine *engine, ScCancelToken *token);

/*
 * Releases an engine output. Idempotent on an all-zero descriptor. Never call
 * this on a host-owned input descriptor.
 */
void sc_buffer_release(ScImageBuffer *image);

void sc_error_release(ScError *error);

#ifdef __cplusplus
}
#endif

#endif /* STUDIOCORE_IMAGE_ENGINE_H */
