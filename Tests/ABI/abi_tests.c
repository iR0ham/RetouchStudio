/*
 * StudioCore C ABI v0 tests.
 *
 * The test is plain C11 and links libStudioCoreABI.a + libStudioCore.a. It is
 * the proof that a host which does not share Swift's ABI can read and write a
 * project, derive a render plan and drive the undo history through
 * studioscore_core.h alone.
 *
 * Run with Tests/run-abi.sh; fixtures live in Tests/ABI/Fixtures.
 */

#include "studioscore_core.h"

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(SC_CORE_ABI == 1u, "ABI version changed");
_Static_assert(SC_CORE_OK == 0, "OK must be zero");
_Static_assert(SC_CORE_INVALID_ARGUMENT == 1, "status numbering changed");
_Static_assert(SC_CORE_INVALID_JSON == 2, "status numbering changed");
_Static_assert(SC_CORE_PROJECT_TOO_NEW == 3, "status numbering changed");
_Static_assert(SC_CORE_UNSUPPORTED_FEATURE == 4, "status numbering changed");
_Static_assert(SC_CORE_INVALID_DOCUMENT == 5, "status numbering changed");
_Static_assert(SC_CORE_INTERNAL == 6, "status numbering changed");
_Static_assert(sizeof(ScCoreStatus) == 4, "ScCoreStatus must be 32-bit");
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
    _Generic(&sc_history_create,
             ScCoreStatus (*)(const uint8_t *, size_t, ScCoreHistory **,
                              ScCoreBytes *): 1,
             default: 0),
    "sc_history_create signature changed");
_Static_assert(_Generic(&sc_core_bytes_release,
                        void (*)(ScCoreBytes *): 1, default: 0),
               "sc_core_bytes_release signature changed");

static int checks;
static int failures;

static void ok(int condition, const char *what) {
  checks++;
  if (!condition) {
    failures++;
    fprintf(stderr, "  fail: %s\n", what);
  }
}

/* MARK: - Fixtures */

static uint8_t *load(const char *name, size_t *length) {
  const char *root = getenv("STUDIOCORE_ROOT");
  char path[4096];
  if (root == NULL || root[0] == '\0') {
    fprintf(stderr, "STUDIOCORE_ROOT is not set\n");
    exit(2);
  }
  snprintf(path, sizeof path, "%s/Tests/ABI/Fixtures/%s", root, name);
  FILE *file = fopen(path, "rb");
  if (file == NULL) {
    fprintf(stderr, "cannot open %s\n", path);
    exit(2);
  }
  if (fseek(file, 0, SEEK_END) != 0) { fprintf(stderr, "fseek failed\n"); exit(2); }
  long size = ftell(file);
  if (size <= 0) { fprintf(stderr, "%s is empty\n", path); exit(2); }
  rewind(file);
  uint8_t *bytes = malloc((size_t)size);
  if (bytes == NULL || fread(bytes, 1, (size_t)size, file) != (size_t)size) {
    fprintf(stderr, "cannot read %s\n", path);
    exit(2);
  }
  fclose(file);
  *length = (size_t)size;
  return bytes;
}

static int contains(const uint8_t *bytes, size_t length, const char *needle) {
  size_t target = strlen(needle);
  if (target == 0 || target > length) { return 0; }
  for (size_t i = 0; i + target <= length; i++) {
    if (memcmp(bytes + i, needle, target) == 0) { return 1; }
  }
  return 0;
}

static int bytes_equal(const ScCoreBytes *buffer,
                       const uint8_t *expected, size_t length) {
  return buffer->len == length && buffer->ptr != NULL &&
         memcmp(buffer->ptr, expected, length) == 0;
}

static int has_code(const ScCoreBytes *error, const char *code) {
  char needle[128];
  snprintf(needle, sizeof needle, "\"code\" : \"%s\"", code);
  return error->ptr != NULL && contains(error->ptr, error->len, needle);
}

/* MARK: - Project round trip */

static void test_project_round_trip(void) {
  for (int v4 = 0; v4 <= 1; v4++) {
    const char *name = v4 ? "project-v4-unknown.json" : "project-v3.json";
    size_t length = 0;
    uint8_t *file = load(name, &length);
    ScCoreBytes document = {0};
    ScCoreBytes context = {0};
    ScCoreBytes error = {0};

    ScCoreStatus status = sc_project_read(file, length, &document, &context, &error);
    ok(status == SC_CORE_OK, "read returns OK");
    ok(document.ptr != NULL && document.len > 0, "read returns a document");
    ok(context.ptr != NULL && context.len > 0, "read returns a context");
    ok(document.ptr != NULL && contains(document.ptr, document.len, "\"version\" : 4"),
       "the document is canonical v4");
    char expectedVersion[48];
    snprintf(expectedVersion, sizeof expectedVersion, "\"version\" : %d", v4 ? 4 : 3);
    ok(context.ptr != NULL &&
           contains(context.ptr, context.len, expectedVersion),
       "the context keeps the file's version");

    if (v4) {
      ok(context.ptr != NULL &&
             contains(context.ptr, context.len, "futureDocumentField"),
         "the context keeps an unknown top-level key");
      ok(context.ptr != NULL &&
             contains(context.ptr, context.len, "futureSlider"),
         "the context keeps an unknown field inside adjustments");
      ok(document.ptr == NULL ||
             !contains(document.ptr, document.len, "futureSlider"),
         "the editable document drops fields this build does not model");
    }

    ScCoreBytes project = {0};
    ScCoreBytes writeError = {0};
    status = sc_project_write(document.ptr, document.len,
                              context.ptr, context.len, &project, &writeError);
    ok(status == SC_CORE_OK, "write returns OK");
    ok(bytes_equal(&project, file, length),
       v4 ? "v4 save reproduces the file byte for byte"
          : "v3 save reproduces the file byte for byte");

    /* An edit to a modelled field keeps every unknown field. */
    if (v4 && document.ptr != NULL) {
      size_t editLength = document.len;
      uint8_t *edited = malloc(editLength);
      ok(edited != NULL, "edited document buffer allocated");
      if (edited != NULL) {
        memcpy(edited, document.ptr, editLength);
        const char *before = "\"exposure\" : 12";
        const char *after = "\"exposure\" : 14";
        size_t hit = 0;
        int found = 0;
        for (size_t i = 0; i + strlen(before) <= editLength; i++) {
          if (memcmp(edited + i, before, strlen(before)) == 0) {
            hit = i;
            found = 1;
            break;
          }
        }
        ok(found, "the fixture models exposure");
        if (found) {
          memcpy(edited + hit, after, strlen(after));
          ScCoreBytes saved = {0};
          ScCoreBytes saveError = {0};
          status = sc_project_write(edited, editLength,
                                    context.ptr, context.len,
                                    &saved, &saveError);
          ok(status == SC_CORE_OK, "write of an edited document returns OK");
          ok(saved.ptr != NULL &&
                 contains(saved.ptr, saved.len, "\"exposure\" : 14"),
             "the edit reaches the saved file");
          ok(saved.ptr != NULL &&
                 contains(saved.ptr, saved.len, "futureDocumentField") &&
                 contains(saved.ptr, saved.len, "futureSlider"),
             "an edit keeps both unknown fields");
          sc_core_bytes_release(&saved);
          ok(saved.ptr == NULL && saved.len == 0,
             "release zeroes the edited descriptor");
          sc_core_bytes_release(&saveError);
        }
        free(edited);
      }
    }

    ok(project.ptr != NULL, "release is called on an owned buffer");
    sc_core_bytes_release(&project);
    ok(project.ptr == NULL && project.len == 0,
       "release zeroes the project descriptor");
    sc_core_bytes_release(&document);
    sc_core_bytes_release(&context);
    sc_core_bytes_release(&error);
    free(file);
  }
}

/* MARK: - Refusals */

static void test_refusals(void) {
  size_t length = 0;
  uint8_t *tooNew = load("project-too-new.json", &length);
  ScCoreBytes document = {0};
  ScCoreBytes context = {0};
  ScCoreBytes error = {0};

  ScCoreStatus status = sc_project_read(tooNew, length, &document, &context, &error);
  ok(status == SC_CORE_PROJECT_TOO_NEW, "a newer file reports PROJECT_TOO_NEW");
  ok(has_code(&error, "project_too_new"), "the error code is project_too_new");
  ok(document.ptr == NULL && context.ptr == NULL,
     "a refused read writes no document");
  sc_core_bytes_release(&document);
  sc_core_bytes_release(&context);
  sc_core_bytes_release(&error);
  free(tooNew);

  const char *broken = "{\"imagePath\": ";
  status = sc_project_read((const uint8_t *)broken, strlen(broken),
                           &document, &context, &error);
  ok(status == SC_CORE_INVALID_JSON, "non-JSON bytes report INVALID_JSON");
  ok(has_code(&error, "invalid_json"), "the error code is invalid_json");
  sc_core_bytes_release(&document);
  sc_core_bytes_release(&context);
  sc_core_bytes_release(&error);

  status = sc_project_read(NULL, 0, &document, &context, &error);
  ok(status == SC_CORE_INVALID_ARGUMENT, "a NULL buffer reports INVALID_ARGUMENT");
  ok(has_code(&error, "invalid_argument"), "the error code is invalid_argument");
  sc_core_bytes_release(&document);
  sc_core_bytes_release(&context);
  sc_core_bytes_release(&error);

  const char *empty = "{}";
  status = sc_project_read((const uint8_t *)empty, strlen(empty),
                           NULL, &context, &error);
  ok(status == SC_CORE_INVALID_ARGUMENT, "a NULL out_document is refused");
  sc_core_bytes_release(&context);
  sc_core_bytes_release(&error);

  /* The error parameter is optional: the status alone is still correct. */
  status = sc_project_read((const uint8_t *)broken, strlen(broken),
                           &document, &context, NULL);
  ok(status == SC_CORE_INVALID_JSON, "a NULL out_error is accepted");

  /* Valid JSON that is not a project document. */
  const char *notAProject = "[1, 2, 3]";
  status = sc_project_read((const uint8_t *)notAProject, strlen(notAProject),
                           &document, &context, &error);
  ok(status == SC_CORE_INVALID_DOCUMENT,
     "a JSON array is not a project document");
  ok(has_code(&error, "invalid_document"), "the error code is invalid_document");
  sc_core_bytes_release(&document);
  sc_core_bytes_release(&context);
  sc_core_bytes_release(&error);
}

/* MARK: - Render plan */

static void test_render_plan(void) {
  size_t requestLength = 0, sourceLength = 0, planLength = 0;
  uint8_t *request = load("render-request.json", &requestLength);
  uint8_t *source = load("render-source.json", &sourceLength);
  uint8_t *expected = load("render-plan.json", &planLength);

  ScCoreBytes plan = {0};
  ScCoreBytes error = {0};
  ScCoreStatus status = sc_render_plan(request, requestLength,
                                       source, sourceLength, &plan, &error);
  ok(status == SC_CORE_OK, "render plan returns OK");
  ok(bytes_equal(&plan, expected, planLength),
     "the plan matches the pinned fixture byte for byte");
  sc_core_bytes_release(&plan);
  sc_core_bytes_release(&error);

  const char *badRequest = "{\"format\": \"webp\"}";
  status = sc_render_plan((const uint8_t *)badRequest, strlen(badRequest),
                          source, sourceLength, &plan, &error);
  ok(status == SC_CORE_INVALID_DOCUMENT,
     "an unknown format is an INVALID_DOCUMENT");
  ok(has_code(&error, "invalid_request"), "the error code is invalid_request");
  sc_core_bytes_release(&plan);
  sc_core_bytes_release(&error);

  const char *badSource = "{}";
  status = sc_render_plan(request, requestLength,
                          (const uint8_t *)badSource, strlen(badSource),
                          &plan, &error);
  ok(status == SC_CORE_INVALID_DOCUMENT, "an empty source is refused");
  ok(has_code(&error, "invalid_source"), "the error code is invalid_source");
  sc_core_bytes_release(&plan);
  sc_core_bytes_release(&error);

  const char *badJSON = "sRGB";
  status = sc_render_plan((const uint8_t *)badJSON, strlen(badJSON),
                          source, sourceLength, &plan, &error);
  ok(status == SC_CORE_INVALID_JSON, "a non-JSON request is refused");
  sc_core_bytes_release(&plan);
  sc_core_bytes_release(&error);

  status = sc_render_plan(NULL, 0, source, sourceLength, &plan, &error);
  ok(status == SC_CORE_INVALID_ARGUMENT, "a NULL request is refused");
  sc_core_bytes_release(&plan);
  sc_core_bytes_release(&error);

  free(request);
  free(source);
  free(expected);
}

/* MARK: - History */

/* The bytes and their length are separate arguments. The length is computed at
   the call site from the same string the bytes come from, so no argument list
   reads a variable another argument writes — the old out-parameter form was
   unsequenced and let a compiler pass a stale zero for the initial state. */
static const uint8_t *state(const char *bytes) {
  return (const uint8_t *)bytes;
}

static int state_is(const ScCoreBytes *buffer, const char *expected) {
  size_t length = strlen(expected);
  return buffer->len == length && buffer->ptr != NULL &&
         memcmp(buffer->ptr, expected, length) == 0;
}

static void test_history(void) {
  ScCoreBytes error = {0};
  ScCoreHistory *history = NULL;
  ok(sc_history_create(state("A"), strlen("A"), &history, &error) == SC_CORE_OK,
     "create returns OK");
  ok(history != NULL, "create returns a handle");

  ScCoreBytes step = {0};
  ok(sc_history_commit(history, state("B"), strlen("B")) == SC_CORE_OK,
     "commit returns OK");
  ok(sc_history_commit(history, state("B"), strlen("B")) == SC_CORE_OK,
     "a repeated commit is a no-op");

  int32_t canUndo = -1, canRedo = -1;
  ok(sc_history_flags(history, state("B"), strlen("B"),
                      &canUndo, &canRedo) == SC_CORE_OK,
     "flags returns OK");
  ok(canUndo == 1 && canRedo == 0, "one step back, no redo");

  int32_t dirty = -1;
  ok(sc_history_is_dirty(history, state("B"), strlen("B"), &dirty) == SC_CORE_OK,
     "is_dirty returns OK");
  ok(dirty == 1, "a step away from the clean state is dirty");

  ok(sc_history_undo(history, state("B"), strlen("B"), &step) == SC_CORE_OK,
     "undo returns OK");
  ok(state_is(&step, "A"), "undo returns the previous state");
  sc_core_bytes_release(&step);

  ok(sc_history_flags(history, state("A"), strlen("A"),
                      &canUndo, &canRedo) == SC_CORE_OK,
     "flags after undo returns OK");
  ok(canUndo == 0 && canRedo == 1, "nothing further back, one step forward");

  ok(sc_history_redo(history, state("A"), strlen("A"), &step) == SC_CORE_OK,
     "redo returns OK");
  ok(state_is(&step, "B"), "redo returns the next state");
  sc_core_bytes_release(&step);

  /* A new commit after undo discards the redo branch. */
  ok(sc_history_undo(history, state("B"), strlen("B"), &step) == SC_CORE_OK,
     "second undo returns OK");
  ok(state_is(&step, "A"), "second undo returns the previous state");
  sc_core_bytes_release(&step);
  ok(sc_history_commit(history, state("C"), strlen("C")) == SC_CORE_OK,
     "commit after undo returns OK");
  ok(sc_history_flags(history, state("C"), strlen("C"),
                      &canUndo, &canRedo) == SC_CORE_OK,
     "flags on the new branch returns OK");
  ok(canUndo == 1 && canRedo == 0, "the redo branch is discarded");

  ok(sc_history_undo(history, state("C"), strlen("C"), &step) == SC_CORE_OK,
     "undo on the new branch returns OK");
  ok(state_is(&step, "A"), "undo on the new branch returns A");
  sc_core_bytes_release(&step);
  ok(sc_history_undo(history, state("A"), strlen("A"), &step) == SC_CORE_OK,
     "undo at the beginning returns OK");
  ok(step.ptr == NULL && step.len == 0, "undo at the beginning writes no state");
  sc_core_bytes_release(&step);
  ok(sc_history_redo(history, state("A"), strlen("A"), &step) == SC_CORE_OK,
     "redo after the last undo returns OK");
  ok(state_is(&step, "C"), "redo returns the abandoned state");
  sc_core_bytes_release(&step);

  ok(sc_history_mark_clean(history, state("C"), strlen("C")) == SC_CORE_OK,
     "mark_clean returns OK");
  ok(sc_history_is_dirty(history, state("C"), strlen("C"), &dirty) == SC_CORE_OK,
     "is_dirty after mark_clean returns OK");
  ok(dirty == 0, "mark_clean makes the current state clean");
  ok(sc_history_is_dirty(history, state("A"), strlen("A"), &dirty) == SC_CORE_OK,
     "is_dirty on another state returns OK");
  ok(dirty == 1, "another state is dirty");

  ok(sc_history_flags(history, state("C"), strlen("C"), NULL, &canRedo) ==
         SC_CORE_INVALID_ARGUMENT,
     "flags requires both out values");
  ok(sc_history_commit(NULL, state("A"), strlen("A")) ==
         SC_CORE_INVALID_ARGUMENT,
     "a NULL handle is refused");

  sc_history_destroy(history);
  sc_history_destroy(NULL);
  sc_core_bytes_release(&error);
}

static void test_history_limit(void) {
  ScCoreBytes error = {0};
  ScCoreHistory *history = NULL;
  char text[16];
  ok(sc_history_create(state("0"), strlen("0"), &history, &error) == SC_CORE_OK,
     "step-limit history created");
  for (int i = 1; i <= 120; i++) {
    snprintf(text, sizeof text, "%d", i);
    if (sc_history_commit(history, state(text), strlen(text)) != SC_CORE_OK) {
      ok(0, "step-limit commit returns OK");
      break;
    }
  }

  char current[16] = "120";
  int steps = 0;
  ScCoreBytes step = {0};
  while (steps < 200 &&
         sc_history_undo(history, state(current), strlen(current), &step) ==
             SC_CORE_OK &&
         step.ptr != NULL) {
    steps++;
    snprintf(current, sizeof current, "%.*s", (int)step.len,
             (const char *)step.ptr);
    sc_core_bytes_release(&step);
  }
  ok(steps == 100, "history keeps exactly 100 undo steps");
  ok(step.ptr == NULL && step.len == 0, "the empty undo is explicit");
  sc_core_bytes_release(&step);
  sc_history_destroy(history);
  sc_core_bytes_release(&error);
}

/* MARK: - Descriptor ownership */

static void test_release_contract(void) {
  ScCoreBytes zero = {0};
  sc_core_bytes_release(&zero);
  ok(zero.ptr == NULL && zero.len == 0, "release is safe on a zeroed descriptor");
  sc_core_bytes_release(NULL);

  ScCoreBytes owned = {0};
  size_t length = 0;
  uint8_t *file = load("project-v3.json", &length);
  ScCoreBytes context = {0};
  ScCoreBytes error = {0};
  ok(sc_project_read(file, length, &owned, &context, &error) == SC_CORE_OK,
     "descriptor read returns OK");
  ok(owned.ptr != NULL && owned.len > 0, "the descriptor owns a buffer");
  sc_core_bytes_release(&owned);
  ok(owned.ptr == NULL && owned.len == 0, "release zeroes ptr and len");
  sc_core_bytes_release(&owned); /* A second release of a zeroed descriptor. */
  sc_core_bytes_release(&context);
  sc_core_bytes_release(&error);
  free(file);
}

int main(void) {
  ok(sc_core_abi_version() == SC_CORE_ABI, "sc_core_abi_version matches the header");

  test_project_round_trip();
  test_refusals();
  test_render_plan();
  test_history();
  test_history_limit();
  test_release_contract();

  if (failures != 0) {
    fprintf(stderr, "ABI TESTS: FAIL (%d of %d checks)\n", failures, checks);
    return 1;
  }
  printf("ABI TESTS: PASS (%d checks)\n", checks);
  return 0;
}
