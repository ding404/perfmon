#ifndef PERFMON_H
#define PERFMON_H

#include <stdint.h>

typedef struct PerfmonSnapshot {
    double cpu_percent;
    double memory_percent;
    double swap_percent;
    uint64_t rx_bytes_per_sec;
    uint64_t tx_bytes_per_sec;
    uint64_t disk_read_bytes_per_sec;
    uint64_t disk_write_bytes_per_sec;
    uint64_t disk_available_bytes;
    double uptime_seconds;
    uint8_t valid;
} PerfmonSnapshot;

typedef struct PerfmonHandle PerfmonHandle;

PerfmonHandle *perfmon_create(void);
int32_t perfmon_sample(PerfmonHandle *handle, PerfmonSnapshot *out);
void perfmon_destroy(PerfmonHandle *handle);

#endif
