// powerplus-helper: installed setuid root. Only does one thing: a userspace reboot.
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "userspace") != 0) return 2;
    if (setgid(0) != 0 || setuid(0) != 0) {
        if (geteuid() != 0) return 3;
    }
    const char *launchctls[] = { "/var/jb/usr/bin/launchctl", "/var/jb/bin/launchctl", "/usr/bin/launchctl", "/bin/launchctl", NULL };
    for (int i = 0; launchctls[i]; i++) {
        if (access(launchctls[i], X_OK) == 0) {
            pid_t pid = fork();
            if (pid == 0) { execl(launchctls[i], "launchctl", "reboot", "userspace", (char *)NULL); _exit(127); }
            if (pid > 0) { sleep(3); }
        }
    }
    if (access("/var/jb/basebin/jbctl", X_OK) == 0)
        execl("/var/jb/basebin/jbctl", "jbctl", "reboot_userspace", (char *)NULL);
    return 4;
}
