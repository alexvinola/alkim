/*
 * alkim-pty — runs one command on a real pseudo-terminal and relays it
 * over stdin/stdout using Erlang's {packet, 4} framing.
 *
 * The BEAM has no pty of its own, and an Erlang Port cannot resize a
 * terminal or give a child a controlling tty. Interactive harnesses (the
 * Claude Code and Codex TUIs) need both, so this helper owns the pty and
 * Alkim owns this helper — the chain of supervision is unbroken.
 *
 * Framing: every message, in both directions, is a 4-byte big-endian length
 * followed by a payload whose first byte is a tag.
 *
 *   in   'd' <bytes>            keystrokes for the terminal
 *        'r' <rows:16> <cols:16>  window size changed
 *        'k'                     terminate the child
 *   out  'o' <bytes>            terminal output, verbatim
 *        'x' <status:32>        the child exited; nothing follows
 *
 * Closing stdin kills the child: if Alkim dies, no harness is left behind.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <util.h>
#elif defined(__FreeBSD__) || defined(__DragonFly__)
#include <libutil.h>
#else
#include <pty.h>
#endif

#define BUF_SIZE 65536
#define GRACE_SECONDS 2

static int master_fd = -1;
static pid_t child = -1;
static int child_status = 0;
static unsigned char buf[BUF_SIZE];

static int write_all(int fd, const unsigned char *buf, size_t len) {
  size_t done = 0;
  while (done < len) {
    ssize_t n = write(fd, buf + done, len - done);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    done += (size_t)n;
  }
  return 0;
}

static int read_all(int fd, unsigned char *buf, size_t len) {
  size_t done = 0;
  while (done < len) {
    ssize_t n = read(fd, buf + done, len - done);
    if (n == 0) return 0; /* EOF */
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    done += (size_t)n;
  }
  return 1;
}

static int send_frame(unsigned char tag, const unsigned char *body, size_t len) {
  unsigned char header[5];
  uint32_t total = (uint32_t)(len + 1);

  header[0] = (unsigned char)(total >> 24);
  header[1] = (unsigned char)(total >> 16);
  header[2] = (unsigned char)(total >> 8);
  header[3] = (unsigned char)total;
  header[4] = tag;

  if (write_all(STDOUT_FILENO, header, sizeof(header)) < 0) return -1;
  if (len > 0 && write_all(STDOUT_FILENO, body, len) < 0) return -1;
  return 0;
}

static void resize(unsigned short rows, unsigned short cols) {
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_row = rows;
  ws.ws_col = cols;
  ioctl(master_fd, TIOCSWINSZ, &ws);
}

/*
 * Reap the child, keeping its exit status: it is what Alkim reports, so it
 * must survive the shutdown path as well as the normal one.
 *
 * Nothing here may block. This helper exists to guarantee that no harness
 * outlives Alkim, so it must never be the thing that hangs: every wait is
 * bounded, and if a process somehow refuses to die we give up and exit
 * anyway — it is already reparented and has an unblockable SIGKILL pending.
 *
 * Signals go to the process *group*: forkpty makes the child a session
 * leader, so its own children (a TUI's helpers, language servers, shells)
 * share its group and would otherwise survive it.
 */
static void signal_group(int sig) {
  if (kill(-child, sig) < 0 && errno == ESRCH) kill(child, sig);
}

/* 1 when the child was reaped, 0 while it is still there. */
static int try_reap(void) {
  pid_t result = waitpid(child, &child_status, WNOHANG);

  if (result == child || (result < 0 && errno == ECHILD)) {
    child = -1;
    return 1;
  }

  return 0;
}

static void reap_child(int signal_first) {
  if (child <= 0) return;
  if (try_reap()) return;

  if (signal_first) signal_group(SIGTERM);

  for (int i = 0; i < GRACE_SECONDS * 20; i++) {
    if (try_reap()) return;
    usleep(50000);
  }

  signal_group(SIGKILL);

  for (int i = 0; i < 20; i++) {
    if (try_reap()) return;
    usleep(50000);
  }

  /* Out of patience: stop waiting rather than hold the harness's pty open. */
  child = -1;
}

/*
 * Forward everything the terminal has produced. Returns -1 once the pty is
 * finished (EOF, or EIO after the last slave fd closed), 0 when it is merely
 * empty for now.
 */
static int pump_master(void) {
  for (;;) {
    ssize_t n = read(master_fd, buf, sizeof(buf));
    if (n > 0) {
      if (send_frame('o', buf, (size_t)n) < 0) return -1;
      continue;
    }
    if (n == 0) return -1;
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
    return -1;
  }
}

/* One framed message from Alkim. Returns 0 on EOF, -1 on error. */
static int handle_input(void) {
  unsigned char header[4];
  int got = read_all(STDIN_FILENO, header, sizeof(header));
  if (got <= 0) return got;

  uint32_t len = ((uint32_t)header[0] << 24) | ((uint32_t)header[1] << 16) |
                 ((uint32_t)header[2] << 8) | (uint32_t)header[3];
  if (len == 0 || len > BUF_SIZE) return -1;

  unsigned char *payload = malloc(len);
  if (payload == NULL) return -1;

  got = read_all(STDIN_FILENO, payload, len);
  if (got <= 0) {
    free(payload);
    return got;
  }

  int result = 1;
  switch (payload[0]) {
    case 'd':
      if (len > 1 && write_all(master_fd, payload + 1, len - 1) < 0) result = -1;
      break;
    case 'r':
      if (len == 5) {
        resize((unsigned short)((payload[1] << 8) | payload[2]),
               (unsigned short)((payload[3] << 8) | payload[4]));
      }
      break;
    case 'k':
      reap_child(1);
      break;
    default:
      break;
  }

  free(payload);
  return result;
}

int main(int argc, char *argv[]) {
  if (argc < 2) {
    fprintf(stderr, "usage: alkim-pty <command> [args...]\n");
    return 64;
  }

  /* A dying child must not take the relay down with it. */
  signal(SIGPIPE, SIG_IGN);

  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_row = 24;
  ws.ws_col = 80;

  child = forkpty(&master_fd, NULL, NULL, &ws);
  if (child < 0) {
    perror("alkim-pty: forkpty");
    return 71;
  }

  if (child == 0) {
    execvp(argv[1], &argv[1]);
    perror("alkim-pty: exec");
    _exit(127);
  }

  /*
   * The master fd is non-blocking and the loop polls: on macOS select() does
   * not reliably report a pty whose slave has closed, so waiting on it alone
   * would leave the helper — and the harness — running forever.
   */
  fcntl(master_fd, F_SETFL, O_NONBLOCK);
  int stdin_open = 1;

  for (;;) {
    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(master_fd, &fds);
    if (stdin_open) FD_SET(STDIN_FILENO, &fds);

    int highest = master_fd > STDIN_FILENO ? master_fd : STDIN_FILENO;
    struct timeval tv = {0, 200000};

    int ready = select(highest + 1, &fds, NULL, NULL, &tv);
    if (ready < 0) {
      if (errno == EINTR) continue;
      break;
    }

    if (ready > 0 && FD_ISSET(master_fd, &fds) && pump_master() < 0) break;

    if (ready > 0 && stdin_open && FD_ISSET(STDIN_FILENO, &fds)) {
      int status = handle_input();
      if (status < 0) break;
      if (status == 0) {
        /* Alkim is gone: kill the harness and stop, there is no reader left. */
        stdin_open = 0;
        reap_child(1);
        break;
      }
    }

    if (child > 0 && waitpid(child, &child_status, WNOHANG) == child) {
      child = -1;
      pump_master();
      break;
    }
  }

  reap_child(1);

  int code = WIFEXITED(child_status) ? WEXITSTATUS(child_status)
                                     : 128 + WTERMSIG(child_status);
  unsigned char status_bytes[4];
  status_bytes[0] = (unsigned char)(code >> 24);
  status_bytes[1] = (unsigned char)(code >> 16);
  status_bytes[2] = (unsigned char)(code >> 8);
  status_bytes[3] = (unsigned char)code;
  send_frame('x', status_bytes, sizeof(status_bytes));

  return 0;
}
