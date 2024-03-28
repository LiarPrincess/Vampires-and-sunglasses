#define _GNU_SOURCE

#include "include/shims.h"
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <unistd.h>
#include <sys/wait.h>

/* =================== */
/* === exit status === */
/* =================== */

int _clib_WIFEXITED(int status) { return WIFEXITED(status); }
int _clib_WEXITSTATUS(int status) { return WEXITSTATUS(status); }
int _clib_WIFSIGNALED(int status) { return WIFSIGNALED(status); }
int _clib_WTERMSIG(int status) { return WTERMSIG(status); }

/* ============= */
/* === fcntl === */
/* ============= */

#if __linux__
const int _CLIB_F_SETPIPE_SZ = F_SETPIPE_SZ;
const int _CLIB_F_GETPIPE_SZ = F_GETPIPE_SZ;
#endif

int _clib_fcntl_2(int fd, int cmd) { return fcntl(fd, cmd); }
int _clib_fcntl_3(int fd, int cmd, int value) { return fcntl(fd, cmd, value); }

/* ================= */
/* === fork exec === */
/* ================= */

const pid_t _CLIB_FORK_EXEC_ERR_PIPE_OPEN = -1;
const pid_t _CLIB_FORK_EXEC_ERR_FORK = -2;
const pid_t _CLIB_FORK_EXEC_ERR_PIPE_READ = -3;
const pid_t _CLIB_FORK_EXEC_CHILD_ERR_DUP2 = -4;
const pid_t _CLIB_FORK_EXEC_CHILD_ERR_PIPE_CLOEXEC = -5;
const pid_t _CLIB_FORK_EXEC_CHILD_ERR_EXEC = -6;

static const int FORK_EXEC_ERR_MESSAGE_SIZE = 2 * sizeof(int);

static void notify_parent_and_exit(int exec_pipe_write, int operation, int err) __attribute__((__noreturn__))
{
  // TODO: Handle failure?
  int buffer[] = {operation, err};
  write(exec_pipe_write, buffer, FORK_EXEC_ERR_MESSAGE_SIZE);
  _exit(127);
}

pid_t _clib_fork_exec(
    const char *_Nonnull path,
    const char *_Nullable const argv[_Nonnull],
    const char *_Nullable const envp[_Nullable],
    const int fd_stdin,
    const int fd_stdout,
    const int fd_stderr,
    int *_Nonnull err_out)
{
  *err_out = 0;

  // Pipe to send errors from the child.
  // Later in child we will set 'O_CLOEXEC' on 'writeEnd'.
  int exec_pipe[2];
  if (pipe(exec_pipe))
  {
    *err_out = errno;
    return _CLIB_FORK_EXEC_ERR_PIPE_OPEN;
  }

  const int exec_pipe_read = exec_pipe[0];
  const int exec_pipe_write = exec_pipe[1];

  pid_t pid = fork();

  if (pid == -1)
  {
    close(exec_pipe_read);
    close(exec_pipe_write);
    *err_out = errno;
    return _CLIB_FORK_EXEC_ERR_FORK;
  }

  // Parent
  if (pid > 0)
  {
    close(exec_pipe_write);

    ssize_t n;
    pid_t result = 0;
    int buffer[2] = {0, 0};

    while (result == 0)
    {
      n = read(exec_pipe_read, buffer, FORK_EXEC_ERR_MESSAGE_SIZE);

      if (n == -1)
      {
        if (errno != EINTR && errno != EAGAIN)
        {
          result = _CLIB_FORK_EXEC_ERR_PIPE_READ;
          *err_out = errno;
        }
      }
      else if (n == 0)
      {
        // Child exec closed the 'exec_pipe_write' -> no error.
        result = pid;
      }
      else if (n == FORK_EXEC_ERR_MESSAGE_SIZE)
      {
        result = buffer[0];
        *err_out = buffer[1];
      }
      else
      {
        result = _CLIB_FORK_EXEC_ERR_PIPE_READ;
        *err_out = EDOM;
      }
    }

    if (result < 0)
    {
      // TODO: waitpid on every error or just some of them? Read error too?
      waitpid(pid, &(int){0}, 0);
    }

    close(exec_pipe_read);
    return result;
  }

  // Child
  // Until 'execve' we are operating in a limited environment,
  // only the 'async-signal-safe' functions can be called, see list at:
  // https://man7.org/linux/man-pages/man7/signal-safety.7.html
  close(exec_pipe_read);

  int err = dup2(fd_stdin, STDIN_FILENO);
  if (err == -1)
  {
    notify_parent_and_exit(exec_pipe_write, _CLIB_FORK_EXEC_CHILD_ERR_DUP2, errno);
  }

  err = dup2(fd_stdout, STDOUT_FILENO);
  if (err == -1)
  {
    notify_parent_and_exit(exec_pipe_write, _CLIB_FORK_EXEC_CHILD_ERR_DUP2, errno);
  }

  err = dup2(fd_stderr, STDERR_FILENO);
  if (err == -1)
  {
    notify_parent_and_exit(exec_pipe_write, _CLIB_FORK_EXEC_CHILD_ERR_DUP2, errno);
  }

  close(fd_stdin);
  close(fd_stdout);
  close(fd_stderr);

  for (int fd = STDERR_FILENO + 1; fd <= getdtablesize(); fd++)
  {
    if (fd != exec_pipe_write)
    {
      close(fd);
    }
  }

  // Close 'exec_pipe_write' on exec.
  // No race condition because we are in a new process without any additional threads.
  err = fcntl(exec_pipe_write, F_SETFD, FD_CLOEXEC);
  if (err == -1)
  {
    notify_parent_and_exit(exec_pipe_write, _CLIB_FORK_EXEC_CHILD_ERR_PIPE_CLOEXEC, errno);
  }

  for (int i = 1; i < NSIG; i++)
  {
    signal(i, SIG_DFL);
  }

  sigset_t sigset_all;
  sigfillset(&sigset_all);
  sigprocmask(SIG_UNBLOCK, &sigset_all, NULL);

  // This will close 'exec_pipe_write' because of 'FD_CLOEXEC'.
  execve(path, argv, envp);

  // We should never get here!
  notify_parent_and_exit(exec_pipe_write, _CLIB_FORK_EXEC_CHILD_ERR_EXEC, errno);
}
