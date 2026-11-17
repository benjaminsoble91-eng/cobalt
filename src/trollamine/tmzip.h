#ifndef TM_ZIP_H
#define TM_ZIP_H
#include <stddef.h>
int tm_extract_zip(const char *zip_path, const char *dest_dir, char *err, size_t errlen);
#endif
