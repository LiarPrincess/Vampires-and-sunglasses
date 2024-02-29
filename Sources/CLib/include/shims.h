#ifndef shims_h
#define shims_h

int _clib_WIFEXITED(int status);
int _clib_WEXITSTATUS(int status);
int _clib_WIFSIGNALED(int status);
int _clib_WTERMSIG(int status);

#if __linux__
const int _clib_F_SETPIPE_SZ;
const int _clib_F_GETPIPE_SZ;
#endif

int _clib_fcntl_2(int fd, int cmd);
int _clib_fcntl_3(int fd, int cmd, int value);

#endif /* shims_h */
