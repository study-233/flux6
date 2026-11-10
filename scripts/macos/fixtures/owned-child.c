// Test and isolated acceptance builds only. Never shipped in FreeV6.app.
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

// Acceptance build only: retain mode, preferred node and traffic counters in a
// separate process. EOF releases the child even if the UI crashes. This branch
// opens no sockets and has no access to system proxy or DNS.
static int session_fixture(void) {
    char line[64], mode[8] = "rule";
    int selected = -1, chain = 0, sample = 0, zero = 0;
    unsigned long long uploaded = 0, downloaded = 0;
    while (fgets(line, sizeof(line), stdin)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!strcmp(line, "STOP")) { puts("STOPPED"); fflush(stdout); return 0; }
        if (!strcmp(line, "ZERO 1")) zero = 1;
        else if (!strcmp(line, "ZERO 0")) zero = 0;
        else if (!strcmp(line, "MODE global")) strcpy(mode, "global");
        else if (!strcmp(line, "MODE direct")) strcpy(mode, "direct");
        else if (!strcmp(line, "MODE rule")) strcpy(mode, "rule");
        else if (!strncmp(line, "NODE ", 5) || !strncmp(line, "CHAIN ", 6)) {
            int value; char tail;
            int is_chain = line[0] == 'C';
            if (sscanf(line + (is_chain ? 6 : 5), "%d%c", &value, &tail) != 1 || value < (is_chain ? 0 : -1) || value > 199) return 96;
            if (is_chain) chain = value; else selected = value;
        } else if (!strncmp(line, "DELAY ", 6)) {
            int index; char tail;
            if (sscanf(line + 6, "%d%c", &index, &tail) != 1 || index < 0 || index > 199) return 96;
            printf("DELAY %d\n", 12 + (index * 7) % 29); fflush(stdout); continue;
        } else if (!strcmp(line, "TRAFFIC")) {
            static const unsigned int profile[] = {2, 3, 2, 6, 8, 7, 4, 6, 5, 4, 6, 3};
            unsigned int n = zero ? 0 : profile[(sample++) % 12];
            unsigned int up = n * 31250, down = n * 232000;
            uploaded += up * 2; downloaded += down * 2;
            printf("TRAFFIC %u %u %llu %llu\n", up, down, uploaded, downloaded); fflush(stdout); continue;
        } else if (strcmp(line, "STATE")) return 96;
        printf("STATE %s %d %d\n", mode, selected, chain);
        fflush(stdout);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) return 90;
    if (!strcmp(argv[1], "session-fixture") && argc == 2) return session_fixture();
    // A bounded fixture for the real launchd job runner. The product core has
    // its own parser; this test executable is never bundled with the live app.
    if (!strcmp(argv[1], "-t") && argc == 6 && !strcmp(argv[2], "-d") && !strcmp(argv[4], "-f")) {
        alarm(30);
        int env_count = 0;
        for (char **item = environ; *item; ++item) ++env_count;
        if (env_count != 3 || !getenv("PATH") || !getenv("LANG") || !getenv("LC_ALL")) return 51;
        char mode[32] = {0};
        FILE *config = fopen(argv[5], "r");
        if (!config || !fgets(mode, sizeof(mode), config)) return 92;
        fclose(config);
        if (!strcmp(mode, "exit37")) return 37;
        if (!strcmp(mode, "ignore-term") && signal(SIGTERM, SIG_IGN) == SIG_ERR) return 49;
        if (strcmp(mode, "ignore-term") && strcmp(mode, "wait")) return 93;
        char ready_path[4096];
        int length = snprintf(ready_path, sizeof(ready_path), "%s/child-ready", argv[3]);
        if (length < 0 || (size_t)length >= sizeof(ready_path)) return 94;
        int ready = open(ready_path, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (ready < 0) return 50;
        close(ready);
        for (;;) pause();
    }
    if (!strcmp(argv[1], "exit")) return 37;
    if (!strcmp(argv[1], "output")) {
        fprintf(stderr, "must-not-be-captured");
        printf("bounded output\n");
        return 37;
    }
    if (!strcmp(argv[1], "flood")) {
        char noise[4096]; memset(noise, 'x', sizeof(noise));
        for (int i = 0; i < 512; ++i) if (write(STDOUT_FILENO, noise, sizeof(noise)) < 0) return 95;
        return 0;
    }
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
        alarm(30);
        if (signal(SIGTERM, SIG_IGN) == SIG_ERR) return 49;
        int ready = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (ready < 0) return 50;
        close(ready);
        for (;;) pause();
    }
    if (!strcmp(argv[1], "wait")) { for (;;) pause(); }
    return 91;
}
