/*
 * StudioCore C ABI v0 — document rules for non-Swift hosts.
 *
 * Status: IMPLEMENTED. The functions below are compiled from
 * Sources/StudioCoreABI into a static library by Tests/run-abi.sh and are
 * exercised by Tests/ABI/abi_tests.c on the macOS host.
 *
 * Scope: project read/write, the export render plan and the undo history. It
 * intentionally handles no pixels; a host owns decode, render and encode. This
 * header is not the image-engine contract in
 * Tests/Conformance/ABI/studioscore_image_engine.h, which remains an
 * unimplemented draft. The two headers share no type or constant names, so a
 * translation unit may include either one but not both.
 *
 * Data: every payload is a byte slice, usually UTF-8 JSON. Strings are not
 * NUL-terminated; always read `len`.
 *
 * Ownership:
 *   - Requests (state, document, context, JSON inputs) are host-owned and must
 *     stay valid for the call only.
 *   - Every buffer written to an out-parameter (document, context, project,
 *     plan, state, error) is engine-owned until sc_core_bytes_release. Release
 *     each one exactly once; the function zeroes the descriptor.
 *   - sc_history_create returns a handle owned by the host until
 *     sc_history_destroy.
 *
 * Threading: the functions keep no global state. A history handle is not
 * thread-safe; one open document is one handle on one thread.
 *
 * Errors: a non-zero status is always paired with a UTF-8 JSON object in
 * out_error when that parameter is non-NULL. Its `code` field is stable; its
 * `message` is English for diagnostics and must not be shown untranslated.
 *
 * Versioning: SC_CORE_ABI is the layout and behaviour version. Adding a field
 * to ScCoreBytes or a function is allowed within one version; renaming,
 * removing or reordering requires a new one.
 */

#ifndef STUDIOCORE_CORE_H
#define STUDIOCORE_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SC_CORE_ABI 1u

typedef int32_t ScCoreStatus;

enum {
  SC_CORE_OK = 0,
  /* A NULL or zero-length argument that the call requires. */
  SC_CORE_INVALID_ARGUMENT = 1,
  /* The bytes are not valid JSON. */
  SC_CORE_INVALID_JSON = 2,
  /* The project file declares a version newer than this build reads. */
  SC_CORE_PROJECT_TOO_NEW = 3,
  /* The project file requires a capability this build does not implement. */
  SC_CORE_UNSUPPORTED_FEATURE = 4,
  /* Valid JSON, but not a document, context, request or source this build
   * accepts. */
  SC_CORE_INVALID_DOCUMENT = 5,
  SC_CORE_INTERNAL = 6
};

/* An engine-owned byte range. Release with sc_core_bytes_release. */
typedef struct ScCoreBytes {
  uint8_t *ptr;
  size_t len;
} ScCoreBytes;

typedef struct ScCoreHistory ScCoreHistory;

uint32_t sc_core_abi_version(void);

/* Frees an engine-owned buffer and zeroes the descriptor. Safe on an all-zero
 * descriptor. Never call it on host-owned input. */
void sc_core_bytes_release(ScCoreBytes *bytes);

/*
 * Reads a project file of any version this build supports.
 *
 * out_document receives the current canonical v4 record as JSON: what the host
 * edits. It is version 4 even when the file was version 3.
 * out_context receives the JSON write context: the original file version and
 * every top-level key and nested record field this build does not model. It
 * must be passed back unchanged to sc_project_write, or the save silently drops
 * data a newer build wrote.
 */
ScCoreStatus sc_project_read(const uint8_t *bytes, size_t length,
                             ScCoreBytes *out_document,
                             ScCoreBytes *out_context,
                             ScCoreBytes *out_error);

/*
 * Writes a project file from the document returned by sc_project_read, or from
 * an edited copy of it, plus its unchanged context.
 *
 * The context is authoritative for version and preservation data; unknown keys
 * added to the document itself are not written. The document is still parsed
 * and validated first, so a document this build does not understand is refused
 * instead of being rewritten.
 */
ScCoreStatus sc_project_write(const uint8_t *document, size_t document_length,
                              const uint8_t *context, size_t context_length,
                              ScCoreBytes *out_project,
                              ScCoreBytes *out_error);

/*
 * Decides the complete pass contract for one export.
 *
 * request is a JSON object with the RenderRequest fields; source is a JSON
 * object with the RenderSourceDescription fields (pixelSize {width,height},
 * photoAspect, faceCount, colorProfileName). out_plan receives a canonical
 * RenderPlan JSON object. The same inputs produce the same plan on every
 * platform, which is what the macOS app and a Windows host are compared on.
 */
ScCoreStatus sc_render_plan(const uint8_t *request, size_t request_length,
                            const uint8_t *source, size_t source_length,
                            ScCoreBytes *out_plan,
                            ScCoreBytes *out_error);

/*
 * Undo history over opaque states.
 *
 * States are compared byte-for-byte, so a host must pass the same canonical
 * encoding every time — for a project document, the document bytes from
 * sc_project_read, which are canonical v4. Equal JSON with different key
 * order, spacing or number spelling is a different state. (A v3 file written
 * back by sc_project_write is not a safe history state: v3 encodes analysis
 * regions as an unordered set.)
 */
ScCoreStatus sc_history_create(const uint8_t *state, size_t state_length,
                               ScCoreHistory **out_history,
                               ScCoreBytes *out_error);

void sc_history_destroy(ScCoreHistory *history);

/* Records one step unless `state` equals the last recorded state. A new step
 * discards the redo branch. At most 100 undo steps are kept. */
ScCoreStatus sc_history_commit(ScCoreHistory *history,
                               const uint8_t *state, size_t state_length);

/* Step back or forward. Returns SC_CORE_OK with an empty out_state when there
 * is nothing to undo or redo; otherwise the prior/next state is copied out. */
ScCoreStatus sc_history_undo(ScCoreHistory *history,
                             const uint8_t *current, size_t current_length,
                             ScCoreBytes *out_state);

ScCoreStatus sc_history_redo(ScCoreHistory *history,
                             const uint8_t *current, size_t current_length,
                             ScCoreBytes *out_state);

/* 1 when an undo/redo step is available for `current`, else 0. */
ScCoreStatus sc_history_flags(ScCoreHistory *history,
                              const uint8_t *current, size_t current_length,
                              int32_t *out_can_undo, int32_t *out_can_redo);

/* Moves the clean baseline without touching the stacks, for save and discard. */
ScCoreStatus sc_history_mark_clean(ScCoreHistory *history,
                                   const uint8_t *state, size_t state_length);

/* 1 when `current` differs from the clean baseline, else 0. */
ScCoreStatus sc_history_is_dirty(ScCoreHistory *history,
                                 const uint8_t *current, size_t current_length,
                                 int32_t *out_dirty);

#ifdef __cplusplus
}
#endif

#endif /* STUDIOCORE_CORE_H */
