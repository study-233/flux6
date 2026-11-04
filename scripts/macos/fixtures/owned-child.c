// Test-only child. Never included in the application bundle.
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

int main(int argc, char **argv) {
    if (argc < 2) return 90;
    if (!strcmp(argv[1], "exit")) return 37;
    if (!strcmp(argv[1], "inspect") && argc == 4) {
        // Parent deliberately opens this descriptor without close-on-exec.
        errno = 0;
        if (fcntl(atoi(argv[2]), F_GETFD) != -1 || errno != EBADF) return 41;
        if (getenv("FREEV6_CHILD_SECRET") || getenv("HTTP_PROXY") || getenv("HOME")) return 42;
        int env_count = 0;
        for (char **item = environ; *item; ++item) ++env_count;
        if (env_count != 3 || !getenv("PATH") || !getenv("LANG") || !getenv("LC_ALL")) return 51;
        char path[4096];
        if (!getcwd(path, sizeof(path)) || strcmp(path, argv[3])) return 43;
        if (getpgrp() != getpid()) return 44;
        sigset_t mask;
        if (sigprocmask(SIG_SETMASK, NULL, &mask) || sigismember(&mask, SIGTERM)) return 45;
        char byte;
        if (read(STDIN_FILENO, &byte, 1) != 0) return 46;
        // More than a pipe buffer: accidental PIPE redirection without a
        // consumer would block. Content must never enter test/daemon output.
        char noise[4096]; memset(noise, 'x', sizeof(noise));
        for (int i = 0; i < 256; ++i) {
            if (write(STDOUT_FILENO, noise, sizeof(noise)) != sizeof(noise)) return 47;
            if (write(STDERR_FILENO, noise, sizeof(noise)) != sizeof(noise)) return 48;
        }
        return 0;
    }
    if (!strcmp(argv[1], "ignore-term") && argc == 3) {
        if (signal(SIGTERM, SIG_IGN) == SIG_ERR) return 49;
        int ready = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (ready < 0) return 50;
        close(ready);
        for (;;) pause();
    }
    if (!strcmp(argv[1], "wait")) { for (;;) pause(); }
    return 91;
}
