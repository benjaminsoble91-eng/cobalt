#ifndef TM_MACHOPATCH_H
#define TM_MACHOPATCH_H
#include <stddef.h>
// Returns 0 on success. *entitlements_xml (if non-NULL on return) must be freed by the caller.
int tm_patch_macho(const char *path, const char *dylib_path, char **entitlements_xml, char *err, size_t errlen);
// Read-only: entitlements XML from a program file's signature (caller frees), or NULL.
char *tm_read_entitlements(const char *path);
#endif
