#ifndef shims_h
#define shims_h

#include <unistd.h>

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

// [Parent] Error when creating the 'exec_pipe'.
const pid_t _CLIB_FORK_EXEC_ERR_PIPE_OPEN;
// [Parent] Error when 'fork'.
const pid_t _CLIB_FORK_EXEC_ERR_FORK;
// [Parent] Error when reading the 'exec_pipe'.
const pid_t _CLIB_FORK_EXEC_ERR_PIPE_READ;
// [Child] Error when setting stdin/stdout/stderr.
const pid_t _CLIB_FORK_EXEC_CHILD_ERR_DUP2;
// [Child] Error when setting FD_CLOEXEC on 'exec_pipe'.
const pid_t _CLIB_FORK_EXEC_CHILD_ERR_PIPE_CLOEXEC;
// [Child] Error when calling 'exec'.
const pid_t _CLIB_FORK_EXEC_CHILD_ERR_EXEC;

// Returns either '0' or one of the '_CLIB_FORK_EXEC_ERR' values.
//
// https://git.musl-libc.org/cgit/musl/plain/src/process/posix_spawn.c
pid_t _clib_fork_exec(
    const char *_Nonnull exec_path,
    const char *_Nullable const argv[_Nonnull],
    const char *_Nullable const envp[_Nullable],
    const int fd_stdin,
    const int fd_stdout,
    const int fd_stderr,
    int *_Nonnull err_out);

#endif /* shims_h */
