#define FUSE_USE_VERSION 31

// -D_FILE_OFFSET_BITS=64 
// https://github.com/winfsp/cgofuse/blob/b8358bce7bce407a8f5a9445723df52ebca32337/fuse/host_cgo.go#L25
// #include <fuse_lowlevel.h>
#include <fuse.h>
