#define _GNU_SOURCE

#include "include/shims.h"
#include <fcntl.h>
#include <sys/wait.h>

int _clib_WIFEXITED(int status) { return WIFEXITED(status); }
int _clib_WEXITSTATUS(int status) { return WEXITSTATUS(status); }
int _clib_WIFSIGNALED(int status) { return WIFSIGNALED(status); }
int _clib_WTERMSIG(int status) { return WTERMSIG(status); }

#if __linux__
const int _clib_F_SETPIPE_SZ = F_SETPIPE_SZ;
const int _clib_F_GETPIPE_SZ = F_GETPIPE_SZ;
#endif

int _clib_fcntl_2(int fd, int cmd) { return fcntl(fd, cmd); }
int _clib_fcntl_3(int fd, int cmd, int value) { return fcntl(fd, cmd, value); }
