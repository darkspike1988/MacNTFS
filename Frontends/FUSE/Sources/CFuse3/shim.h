#define FUSE_USE_VERSION 312
// Plain POSIX stat interface; macFUSE's Darwin attribute extensions are not needed.
#define FUSE_DARWIN_ENABLE_EXTENSIONS 0
#include <fuse_lowlevel.h>
