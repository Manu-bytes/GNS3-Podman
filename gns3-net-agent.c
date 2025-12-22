/*
 * GNS3 Network Agent (C implementation)
 * Runs inside the container to bridge stdin/stdout to a TAP interface.
 * Compile with: gcc -O2 -static -o gns3-net-agent gns3-net-agent.c
 * Note: -static is recommended for portability across diverse container distros.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <net/if.h>
#include <linux/if_tun.h>
#include <errno.h>
#include <signal.h>

#define MAX_BUF_SIZE 65535
#define TUNDEV "/dev/net/tun"

// --- Helper: Execute ip command ---
static int run_ip_command(char *const args[]) {
    pid_t pid = fork();
    if (pid == 0) {
        // Child process
        execvp("ip", args);
        _exit(127); // Command not found
    } else if (pid > 0) {
        int status;
        waitpid(pid, &status, 0);
        return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }
    return -1;
}

// --- Helper: Configure Interface (IP/MAC) ---
static void configure_interface(const char *name, const char *mac) {
    // 1. Set MAC address if provided
    if (mac && strlen(mac) > 0) {
        char *const args[] = {"ip", "link", "set", (char*)name, "address", (char*)mac, NULL};
        if (run_ip_command(args) != 0) {
            fprintf(stderr, "WARN: Failed to set MAC %s on %s\n", mac, name);
        } else {
            fprintf(stderr, "INFO: MAC set to %s\n", mac);
        }
    }

    // 2. Bring interface UP
    char *const args_up[] = {"ip", "link", "set", (char*)name, "up", NULL};
    if (run_ip_command(args_up) != 0) {
        fprintf(stderr, "WARN: Failed to set interface %s UP\n", name);
    } else {
        fprintf(stderr, "INFO: Interface %s is UP\n", name);
    }
}

// --- Helper: Create/Open TAP Device ---
static int open_tap(const char *name) {
    struct ifreq ifr;
    int fd;

    // Try opening the TUN device
    if ((fd = open(TUNDEV, O_RDWR)) < 0) {
        // If device node doesn't exist, try to create it (unlikely in containers but possible)
        // Usually /dev/net/tun is bind-mounted or created by runtime
        perror("ERROR: Cannot open /dev/net/tun");
        return -1;
    }

    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_flags = IFF_TAP | IFF_NO_PI; 
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);

    // Register the TAP interface with the kernel
    if (ioctl(fd, TUNSETIFF, (void *)&ifr) < 0) {
        perror("ERROR: ioctl(TUNSETIFF)");
        close(fd);
        return -1;
    }

    fprintf(stderr, "INFO: TAP device '%s' attached (fd=%d)\n", ifr.ifr_name, fd);
    return fd;
}

// --- Main Bridge Loop ---
static void bridge_loop(int tap_fd) {
    fd_set rd_set;
    int max_fd = (tap_fd > STDIN_FILENO) ? tap_fd : STDIN_FILENO;
    char buffer[MAX_BUF_SIZE];
    ssize_t n;

    fprintf(stderr, "INFO: Starting bridge loop...\n");

    while (1) {
        FD_ZERO(&rd_set);
        FD_SET(tap_fd, &rd_set);
        FD_SET(STDIN_FILENO, &rd_set);

        // Wait for data
        if (select(max_fd + 1, &rd_set, NULL, NULL, NULL) < 0) {
            if (errno == EINTR) continue;
            perror("ERROR: select failed");
            break;
        }

        // 1. Data from Host (Stdin) -> Container (TAP)
        if (FD_ISSET(STDIN_FILENO, &rd_set)) {
            n = read(STDIN_FILENO, buffer, sizeof(buffer));
            if (n <= 0) break; // EOF or Error
      //
            // Write to TAP
            if (write(tap_fd, buffer, n) != n) {
                perror("ERROR: Write to TAP failed");
                break;
            }
        }

        // 2. Data from Container (TAP) -> Host (Stdout)
        if (FD_ISSET(tap_fd, &rd_set)) {
            n = read(tap_fd, buffer, sizeof(buffer));
            if (n <= 0) break; // Error reading TAP

            // Write to Stdout
            if (write(STDOUT_FILENO, buffer, n) != n) {
                // Usually means the pipe to host is broken
                break; 
            }
        }
    }
}

int main(int argc, char *argv[]) {
    const char *ifname = "eth0"; // Default
    const char *mac = NULL;
    int tap_fd;

    // Disable buffering for stdout to ensure low latency
    setvbuf(stdout, NULL, _IONBF, 0);

    // Simple Argument Parsing
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--ifname") == 0 && i + 1 < argc) {
            ifname = argv[++i];
        } else if (strcmp(argv[i], "--mac") == 0 && i + 1 < argc) {
            mac = argv[++i];
        }
    }

    fprintf(stderr, "=== GNS3 Network Agent (C) ===\n");

    // 1. Open TAP
    tap_fd = open_tap(ifname);
    if (tap_fd < 0) {
        fprintf(stderr, "FATAL: Could not create TAP interface.\n");
        return 1;
    }

    // 2. Configure IP/Link
    configure_interface(ifname, mac);

    // 3. Start bridging
    bridge_loop(tap_fd);

    close(tap_fd);
    return 0;
}
