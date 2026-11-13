/*
 * StudioCore C ABI v0 header smoke test.
 *
 * Compiles and runs without Swift, Foundation or any engine implementation. It
 * validates the public header's constants, struct layout and function
 * signatures only; the behaviour is proven by Tests/ABI/abi_tests.c, which
 * links the implementation.
 *
 * This translation unit includes studioscore_core.h. A translation unit may
 * include either this header or studioscore_image_engine.h, never both.
 */

#include "studioscore_core.h"

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#define TYPE_IS(expr, type) _Generic((expr), type: 1, default: 0)

_Static_assert(SC_CORE_ABI == 1u, "ABI version changed");
_Static_assert(SC_CORE_OK == 0, "OK must be zero");
_Static_assert(SC_CORE_INVALID_ARGUMENT == 1, "status numbering changed");
_Static_assert(SC_CORE_INVALID_JSON == 2, "status numbering changed");
_Static_assert(SC_CORE_PROJECT_TOO_NEW == 3, "status numbering changed");
_Static_assert(SC_CORE_UNSUPPORTED_FEATURE == 4, "status numbering changed");
_Static_assert(SC_CORE_INVALID_DOCUMENT == 5, "status numbering changed");
_Static_assert(SC_CORE_INTERNAL == 6, "status numbering changed");

_Static_assert(sizeof(ScCoreStatus) == 4, "ScCoreStatus must be 32-bit");
_Static_assert(TYPE_IS(((ScCoreBytes *)0)->ptr, uint8_t *),
               "ptr must be uint8_t *");
_Static_assert(TYPE_IS(((ScCoreBytes *)0)->len, size_t),
               "len must be size_t");
_Static_assert(offsetof(ScCoreBytes, ptr) == 0, "ptr must be first");
_Static_assert(offsetof(ScCoreBytes, len) == sizeof(uint8_t *),
               "len must follow ptr");
_Static_assert(sizeof(ScCoreBytes) == 2 * sizeof(void *),
               "ScCoreBytes must be exactly two machine words");

_Static_assert(
    _Generic(&sc_project_read,
             ScCoreStatus (*)(const uint8_t *, size_t, ScCoreBytes *,
                              ScCoreBytes *, ScCoreBytes *): 1,
             default: 0),
    "sc_project_read signature changed");
_Static_assert(
    _Generic(&sc_project_write,
             ScCoreStatus (*)(const uint8_t *, size_t, const uint8_t *, size_t,
                              ScCoreBytes *, ScCoreBytes *): 1,
             default: 0),
    "sc_project_write signature changed");
_Static_assert(
    _Generic(&sc_render_plan,
             ScCoreStatus (*)(const uint8_t *, size_t, const uint8_t *, size_t,
                              ScCoreBytes *, ScCoreBytes *): 1,
             default: 0),
    "sc_render_plan signature changed");
_Static_assert(
    _Generic(&sc_history_create,
             ScCoreStatus (*)(const uint8_t *, size_t, ScCoreHistory **,
                              ScCoreBytes *): 1,
             default: 0),
    "sc_history_create signature changed");
_Static_assert(
    _Generic(&sc_history_undo,
             ScCoreStatus (*)(ScCoreHistory *, const uint8_t *, size_t,
                              ScCoreBytes *): 1,
             default: 0),
    "sc_history_undo signature changed");
_Static_assert(_Generic(&sc_history_destroy, void (*)(ScCoreHistory *): 1,
                        default: 0),
               "sc_history_destroy signature changed");
_Static_assert(_Generic(&sc_core_bytes_release, void (*)(ScCoreBytes *): 1,
                        default: 0),
               "sc_core_bytes_release signature changed");

int main(void) {
  printf("studioscore core_abi=%u status_count=%d\n",
         SC_CORE_ABI, SC_CORE_INTERNAL + 1);
  return 0;
}
