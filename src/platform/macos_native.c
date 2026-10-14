#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <arpa/inet.h>
#include <libproc.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/types.h>

#define PERFMON_PROCESS_NAME_MAX 64
#define PERFMON_ENDPOINT_MAX 128

typedef struct {
    int32_t pid;
    uint32_t uid;
    uint8_t protocol;
    uint8_t state;
    uint16_t reserved;
    uint64_t socket_id;
    char comm[PERFMON_PROCESS_NAME_MAX];
    char local[PERFMON_ENDPOINT_MAX];
    char remote[PERFMON_ENDPOINT_MAX];
} PerfmonMacConnection;

static uint64_t statistic_value(CFDictionaryRef statistics, CFStringRef key) {
    const void *value = CFDictionaryGetValue(statistics, key);
    if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return 0;
    }

    int64_t number = 0;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &number) || number < 0) {
        return 0;
    }
    return (uint64_t)number;
}

int perfmon_macos_disk_counters(uint64_t *read_bytes, uint64_t *write_bytes) {
    if (read_bytes == NULL || write_bytes == NULL) {
        return -1;
    }

    *read_bytes = 0;
    *write_bytes = 0;

    CFMutableDictionaryRef matching = IOServiceMatching("IOBlockStorageDriver");
    if (matching == NULL) {
        return -1;
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return -1;
    }

    int found_statistics = 0;
    io_registry_entry_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFTypeRef property = IORegistryEntryCreateCFProperty(
            service,
            CFSTR("Statistics"),
            kCFAllocatorDefault,
            0
        );
        if (property != NULL && CFGetTypeID(property) == CFDictionaryGetTypeID()) {
            CFDictionaryRef statistics = (CFDictionaryRef)property;
            if (CFDictionaryGetValue(statistics, CFSTR("Bytes (Read)")) != NULL ||
                CFDictionaryGetValue(statistics, CFSTR("Bytes (Write)")) != NULL) {
                found_statistics = 1;
                *read_bytes += statistic_value(statistics, CFSTR("Bytes (Read)"));
                *write_bytes += statistic_value(statistics, CFSTR("Bytes (Write)"));
            }
        }
        if (property != NULL) {
            CFRelease(property);
        }
        IOObjectRelease(service);
    }

    IOObjectRelease(iterator);
    return found_statistics ? 0 : -1;
}

static void format_endpoint(
    char *buffer,
    size_t buffer_size,
    const void *address,
    int family,
    int port
) {
    char address_text[INET6_ADDRSTRLEN] = {0};
    if (inet_ntop(family, address, address_text, sizeof(address_text)) == NULL) {
        snprintf(buffer, buffer_size, "*:%d", port);
        return;
    }

    if (family == AF_INET6) {
        snprintf(buffer, buffer_size, "[%s]:%d", address_text, port);
    } else {
        snprintf(buffer, buffer_size, "%s:%d", address_text, port);
    }
}

static void format_socket_endpoints(
    const struct in_sockinfo *socket_info,
    char *local,
    char *remote
) {
    const int family = socket_info->insi_vflag & INI_IPV6 ? AF_INET6 : AF_INET;
    const void *local_address;
    const void *remote_address;

    if (family == AF_INET6) {
        local_address = &socket_info->insi_laddr.ina_6;
        remote_address = &socket_info->insi_faddr.ina_6;
    } else {
        local_address = &socket_info->insi_laddr.ina_46.i46a_addr4;
        remote_address = &socket_info->insi_faddr.ina_46.i46a_addr4;
    }

    format_endpoint(local, PERFMON_ENDPOINT_MAX, local_address, family, socket_info->insi_lport);
    format_endpoint(remote, PERFMON_ENDPOINT_MAX, remote_address, family, socket_info->insi_fport);
}

int perfmon_macos_list_connections(PerfmonMacConnection *output, int capacity) {
    if (output == NULL || capacity <= 0) {
        return -1;
    }

    int pid_count = proc_listallpids(NULL, 0);
    if (pid_count <= 0) {
        return -1;
    }

    pid_t *pids = calloc((size_t)pid_count, sizeof(pid_t));
    if (pids == NULL) {
        return -1;
    }
    int pid_bytes = proc_listallpids(pids, pid_count * (int)sizeof(pid_t));
    if (pid_bytes <= 0) {
        free(pids);
        return -1;
    }

    int written = 0;
    int pid_total = pid_bytes / (int)sizeof(pid_t);
    for (int index = 0; index < pid_total && written < capacity; index++) {
        pid_t pid = pids[index];
        if (pid <= 0) {
            continue;
        }

        struct proc_bsdinfo bsd = {0};
        int bsd_size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd));
        if (bsd_size != (int)sizeof(bsd)) {
            continue;
        }

        char comm[PERFMON_PROCESS_NAME_MAX] = {0};
        if (proc_name(pid, comm, sizeof(comm)) <= 0) {
            snprintf(comm, sizeof(comm), "pid-%d", pid);
        }

        int fd_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (fd_bytes <= 0) {
            continue;
        }
        struct proc_fdinfo *fds = malloc((size_t)fd_bytes);
        if (fds == NULL) {
            continue;
        }
        int actual_fd_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, fd_bytes);
        if (actual_fd_bytes <= 0) {
            free(fds);
            continue;
        }

        int fd_count = actual_fd_bytes / (int)sizeof(struct proc_fdinfo);
        for (int fd_index = 0; fd_index < fd_count && written < capacity; fd_index++) {
            if (fds[fd_index].proc_fdtype != PROX_FDTYPE_SOCKET) {
                continue;
            }

            struct socket_fdinfo socket = {0};
            int socket_size = proc_pidfdinfo(
                pid,
                fds[fd_index].proc_fd,
                PROC_PIDFDSOCKETINFO,
                &socket,
                sizeof(socket)
            );
            if (socket_size != (int)sizeof(socket)) {
                continue;
            }
            if (socket.psi.soi_family != AF_INET && socket.psi.soi_family != AF_INET6) {
                continue;
            }
            if (socket.psi.soi_kind != SOCKINFO_TCP && socket.psi.soi_kind != SOCKINFO_IN) {
                continue;
            }
            if (socket.psi.soi_kind == SOCKINFO_TCP &&
                socket.psi.soi_proto.pri_tcp.tcpsi_state != TSI_S_ESTABLISHED) {
                continue;
            }

            const struct in_sockinfo *socket_info = socket.psi.soi_kind == SOCKINFO_TCP
                ? &socket.psi.soi_proto.pri_tcp.tcpsi_ini
                : &socket.psi.soi_proto.pri_in;

            PerfmonMacConnection *row = &output[written++];
            memset(row, 0, sizeof(*row));
            row->pid = pid;
            row->uid = bsd.pbi_uid;
            row->protocol = (uint8_t)socket.psi.soi_protocol;
            row->state = socket.psi.soi_kind == SOCKINFO_TCP
                ? (uint8_t)socket.psi.soi_proto.pri_tcp.tcpsi_state
                : 0;
            row->socket_id = socket.psi.soi_so;
            snprintf(row->comm, sizeof(row->comm), "%s", comm);
            format_socket_endpoints(socket_info, row->local, row->remote);
        }
        free(fds);
    }

    free(pids);
    return written;
}
