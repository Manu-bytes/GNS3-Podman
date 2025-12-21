/*
 * GNS3 Proxy - C++ Implementation
 * Replaces the Python script for lower latency and CPU usage.
 * Compile with: g++ -O3 -pthread -o gns3-net-proxy gns3-net-proxy.cpp
 */

#include <iostream>
#include <vector>
#include <string>
#include <thread>
#include <cstring>
#include <csignal>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <sys/wait.h>
#include <sys/poll.h>
#include <chrono>
#include <ctime>


// Buffer configuration (same as in Python 65535)
constexpr size_t BUFFER_SIZE = 65535;
volatile std::sig_atomic_t g_running = 1;


// Structure for arguments
struct Config {
    std::string tap_dev;
    std::string cid;
    std::string agent_path;
    std::string ifname;
    std::string mac;
};

// Signal handler (Ctrl+C)
void signal_handler(int signal) {
    if (signal == SIGINT || signal == SIGTERM) {
        g_running = 0;
    }
}

// Function to open the TAP interface
int open_tap(const std::string& name) {
    std::cerr << "DEBUG: Opening /dev/net/tun for attaching to '" << name << "'..." << std::endl;

    int fd = open("/dev/net/tun", O_RDWR);
    if (fd < 0) {
        perror("ERROR opening /dev/net/tun");
        exit(1);
    }

    struct ifreq ifr;
    std::memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
    std::strncpy(ifr.ifr_name, name.c_str(), IFNAMSIZ);

    if (ioctl(fd, TUNSETIFF, (void*)&ifr) < 0) {
        perror(("ERROR attaching to TAP " + name).c_str());
        close(fd);
        exit(1);
    }

    std::cerr << "DEBUG: Successfully attached to TAP '" << name << "'" << std::endl;
    return fd;
}

// Function to check if the container exists
void check_container(const std::string& cid) {
    std::string cmd = "podman ps -q --filter id=" + cid;
    FILE* pipe = popen(cmd.c_str(), "r");
    if (!pipe) {
        std::cerr << "ERROR: Failed to run podman check." << std::endl;
        exit(1);
    }
    char buffer[128];
    std::string result = "";
    while (fgets(buffer, sizeof(buffer), pipe) != NULL) {
        result += buffer;
    }
    pclose(pipe);

    if (result.empty()) {
        std::cerr << "ERROR: Container " << cid << " not found or not running!" << std::endl;
        exit(1);
    }
    std::cerr << "DEBUG: Container " << cid << " is running" << std::endl;
}

// Thread to read stderr from the agent
void read_stderr_thread(int fd, std::string cid) {
    std::cerr << "DEBUG: Starting stderr reader thread for container " << cid << std::endl;
    char buffer[1024];
    ssize_t bytes_read;
    while ((bytes_read = read(fd, buffer, sizeof(buffer) - 1)) > 0) {
        buffer[bytes_read] = '\0';
        std::cerr << "[Agent@" << cid << "] " << buffer;
    }
    std::cerr << "DEBUG: Agent stderr closed for " << cid << std::endl;
}

int main(int argc, char* argv[]) {
    Config config;

    // Simple manual parsing of arguments
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--tap" && i + 1 < argc) config.tap_dev = argv[++i];
        else if (arg == "--cid" && i + 1 < argc) config.cid = argv[++i];
        else if (arg == "--agent-path" && i + 1 < argc) config.agent_path = argv[++i];
        else if (arg == "--ifname" && i + 1 < argc) config.ifname = argv[++i];
        else if (arg == "--mac" && i + 1 < argc) config.mac = argv[++i];
    }

    if (config.tap_dev.empty() || config.cid.empty() || config.agent_path.empty() || config.ifname.empty()) {
        std::cerr << "Usage: " << argv[0] << " --tap <name> --cid <id> --agent-path <path> --ifname <name> [--mac <mac>]" << std::endl;
        return 1;
    }

    // freopen("/tmp/gns3_proxy_cpp_debug.log", "a", stderr);
    auto now = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
    std::cerr << "=== GNS3 Proxy Starting (C++) ===" << std::endl;
    std::cerr << "Timestamp: " << std::ctime(&now);
    std::cerr << "TAP: " << config.tap_dev << std::endl;
    std::cerr << "Container: " << config.cid << std::endl;

    // 1. Open TAP
    int tap_fd = open_tap(config.tap_dev);

    // 2. Verify Container
    check_container(config.cid);

    // 3. Prepare Pipes for the subprocess
    int pipe_stdin[2], pipe_stdout[2], pipe_stderr[2];
    if (pipe(pipe_stdin) < 0 || pipe(pipe_stdout) < 0 || pipe(pipe_stderr) < 0) {
        perror("ERROR creating pipes");
        return 1;
    }

    // 4. Launch agent process (Fork + Exec)
    pid_t pid = fork();
    if (pid == 0) {
        // Redirigir stdin/stdout/stderr
        dup2(pipe_stdin[0], STDIN_FILENO);
        dup2(pipe_stdout[1], STDOUT_FILENO);
        dup2(pipe_stderr[1], STDERR_FILENO);

        // Close unused ends in the child
        close(pipe_stdin[1]);
        close(pipe_stdout[0]);
        close(pipe_stderr[0]);
        close(tap_fd); // The child does not need the TAP.

        // Build arguments for execvp
        std::vector<char*> args;
        args.push_back(strdup("podman"));
        args.push_back(strdup("exec"));
        args.push_back(strdup("-i"));
        args.push_back(strdup(config.cid.c_str()));
        args.push_back(strdup(config.agent_path.c_str()));
        args.push_back(strdup("--ifname"));
        args.push_back(strdup(config.ifname.c_str()));

        if (!config.mac.empty()) {
            args.push_back(strdup("--mac"));
            args.push_back(strdup(config.mac.c_str()));
        }
        args.push_back(nullptr);

        execvp("podman", args.data());

        perror("ERROR executing podman");
        exit(1);
    } else if (pid < 0) {
        perror("ERROR forking");
        return 1;
    }

    // --- PARENT PROCESS (Proxy) ---
    
    // Close pipe ends used by the child
    close(pipe_stdin[0]);
    close(pipe_stdout[1]);
    close(pipe_stderr[1]);

    int agent_in_fd = pipe_stdin[1];   // We write here (goes to the agent's stdin)
    int agent_out_fd = pipe_stdout[0]; // We read from here (comes from the agent's stdout)
    int agent_err_fd = pipe_stderr[0]; // We read stderr

    std::cerr << "DEBUG: Agent process started with PID " << pid << std::endl;

    // Thread for stderr
    std::thread stderr_thread(read_stderr_thread, agent_err_fd, config.cid.substr(0, 8));
    stderr_thread.detach();

    // Configure signals
    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);

    // 5. Main Loop (Bridge Loop)
    // We use poll() instead of select() because it is more modern and efficient in C++
    struct pollfd fds[2];
    fds[0].fd = tap_fd;
    fds[0].events = POLLIN; // Listen to TAP data
    fds[1].fd = agent_out_fd;
    fds[1].events = POLLIN; // Listen to Agent data

    std::vector<char> buffer(BUFFER_SIZE);

    std::cerr << "DEBUG: Entering main bridge loop..." << std::endl;

    while (g_running) {
        // 1000ms timeout to check if g_running changed or the child died
        int ret = poll(fds, 2, 1000); 

        if (ret < 0) {
            if (errno == EINTR) continue; // Interrupted by signal
            perror("ERROR in poll");
            break;
        }

        // Check if the child process is still alive
        int status;
        if (waitpid(pid, &status, WNOHANG) != 0) {
            std::cerr << "ERROR: Agent process exited unexpectedly." << std::endl;
            g_running = 0;
            break;
        }

        if (ret == 0) continue; // Timeout

        // --- DATA FROM THE TAP -> AGENT ---
        if (fds[0].revents & POLLIN) {
            ssize_t n = read(tap_fd, buffer.data(), BUFFER_SIZE);
            if (n <= 0) break; // Error or shutdown

            // Write everything to the agent's stdin
            ssize_t written = 0;
            while (written < n) {
                ssize_t w = write(agent_in_fd, buffer.data() + written, n - written);
                if (w < 0) {
                    perror("ERROR writing to agent stdin");
                    g_running = 0;
                    break;
                }
                written += w;
            }
        }

        // --- DATA FROM AGENT -> TAP ---
        if (fds[1].revents & POLLIN) {
            ssize_t n = read(agent_out_fd, buffer.data(), BUFFER_SIZE);
            if (n <= 0) break; // EOF o error

            // Write everything to the TAP
            ssize_t written = 0;
            while (written < n) {
                ssize_t w = write(tap_fd, buffer.data() + written, n - written);
                if (w < 0) {
                    perror("ERROR writing to TAP");
                    g_running = 0;
                    break;
                }
                written += w;
            }
        }
    }

    std::cerr << "\nDEBUG: Cleaning up..." << std::endl;
    close(tap_fd);
    close(agent_in_fd);
    close(agent_out_fd);
    close(agent_err_fd);

    // Ensure that we kill the child process
    kill(pid, SIGTERM);
    waitpid(pid, nullptr, 0);

    std::cerr << "DEBUG: Proxy shutdown complete" << std::endl;
    return 0;
}
