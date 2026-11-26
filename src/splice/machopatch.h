#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Return the new path for a dependency, or NULL to leave it alone.
typedef const char *(*mp_map_fn)(const char *dep, void *ctx);
typedef void (*mp_dep_cb)(const char *dep, void *ctx);

typedef struct {
    mp_map_fn map;          // rewrite dependencies (may be NULL)
    void *ctx;
    const char *new_id;     // new LC_ID_DYLIB name (may be NULL)
    const char **add;       // LC_LOAD_DYLIB paths to add
    int nadd;
    int weak_add;           // add as LC_LOAD_WEAK_DYLIB instead
} mp_opts;

int mp_is_macho(const char *path);
int mp_is_encrypted(const char *path);
int mp_list_deps(const char *path, mp_dep_cb cb, void *ctx);
int mp_patch(const char *path, const mp_opts *opts, char *err, size_t errlen);

#ifdef __cplusplus
}
#endif
