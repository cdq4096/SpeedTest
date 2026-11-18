#include "bench.h"

#include <algorithm>
#include <chrono>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <string>

#ifndef BENCH_BUILD_TYPE
#define BENCH_BUILD_TYPE "unknown"
#endif

namespace {

using Clock = std::chrono::steady_clock;

struct MemInfo {
    double rss_mb = 0.0;   /* 当前 RSS (VmRSS) */
    double peak_mb = 0.0;  /* 进程峰值 RSS (VmHWM) */
};

struct Options {
    double seconds = 20.0;
    int cpu_pct = 50;
    std::size_t mem_mb = 256;
    std::size_t leak_mb = 0;
    std::uint64_t seed = 0x5EED2024ull;
};

struct Probe {
    std::uint64_t units = 1;
    double seconds = 0.0;
};

double seconds_since(Clock::time_point start) {
    return std::chrono::duration<double>(Clock::now() - start).count();
}

MemInfo read_mem() {
    MemInfo info;
    if (FILE *f = std::fopen("/proc/self/status", "re")) {
        char line[256];
        while (std::fgets(line, sizeof(line), f) != nullptr) {
            unsigned long kb = 0;
            if (std::sscanf(line, "VmRSS: %lu kB", &kb) == 1) {
                info.rss_mb = static_cast<double>(kb) / 1024.0;
            } else if (std::sscanf(line, "VmHWM: %lu kB", &kb) == 1) {
                info.peak_mb = static_cast<double>(kb) / 1024.0;
            }
        }
        std::fclose(f);
    }
    return info;
}

void usage(const char *prog) {
    std::printf(
        "Usage: %s [options]\n"
        "  -t, --seconds <sec>   total measured run time, default 20\n"
        "      --cpu-pct <n>     %% of time spent in libcpuwork (0..100), default 50\n"
        "      --mem-mb <n>      heap working set of libmemwork, default 256\n"
        "      --leak-mb <n>     intentionally leak n MB at exit, default 0\n"
        "      --seed <n>        workload seed (decimal or 0x...), default 0x5EED2024\n"
        "  -h, --help            show this help\n",
        prog);
}

const char *need_value(int argc, char **argv, int &i, const char *opt) {
    if (i + 1 >= argc) {
        std::fprintf(stderr, "error: %s requires a value\n", opt);
        std::exit(2);
    }
    return argv[++i];
}

bool parse_args(int argc, char **argv, Options &opt) {
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "-h" || arg == "--help") {
            usage(argv[0]);
            std::exit(0);
        } else if (arg == "-t" || arg == "--seconds") {
            opt.seconds = std::atof(need_value(argc, argv, i, arg.c_str()));
        } else if (arg == "--cpu-pct") {
            opt.cpu_pct =
                std::atoi(need_value(argc, argv, i, arg.c_str()));
        } else if (arg == "--mem-mb") {
            const long v = std::atol(need_value(argc, argv, i, arg.c_str()));
            opt.mem_mb = v > 0 ? static_cast<std::size_t>(v) : 0;
        } else if (arg == "--leak-mb") {
            const long v = std::atol(need_value(argc, argv, i, arg.c_str()));
            opt.leak_mb = v > 0 ? static_cast<std::size_t>(v) : 0;
        } else if (arg == "--seed") {
            opt.seed = std::strtoull(
                need_value(argc, argv, i, arg.c_str()), nullptr, 0);
        } else {
            std::fprintf(stderr, "error: unknown option: %s\n", arg.c_str());
            usage(argv[0]);
            return false;
        }
    }

    if (opt.seconds <= 0.0) {
        std::fprintf(stderr, "error: --seconds must be > 0\n");
        return false;
    }
    if (opt.mem_mb == 0) {
        std::fprintf(stderr, "error: --mem-mb must be > 0\n");
        return false;
    }
    opt.cpu_pct = std::min(std::max(opt.cpu_pct, 0), 100);
    return true;
}

/* 自适应校准：放大工作量直到单次耗时 >= min_seconds，返回单位耗时 */
template <typename Fn>
Probe calibrate(Fn &&fn, double min_seconds = 0.05) {
    std::uint64_t units = 1u << 16;
    double elapsed = 0.0;

    for (int attempt = 0; attempt < 48; ++attempt) {
        const auto t0 = Clock::now();
        fn(units);
        elapsed = seconds_since(t0);
        if (elapsed >= min_seconds) {
            break;
        }
        double growth = elapsed > 1e-6 ? (min_seconds * 1.3 / elapsed) : 8.0;
        growth = std::min(std::max(growth, 2.0), 64.0);
        units = static_cast<std::uint64_t>(
                    static_cast<double>(units) * growth) +
                1;
    }
    return Probe{units, elapsed};
}

void print_row(const char *name, std::uint64_t units, double sec,
               const MemInfo &mem) {
    std::printf("%-12s %16" PRIu64 " %10.3f %14.2f %10.1f %10.1f\n", name,
                units, sec,
                sec > 0.0 ? static_cast<double>(units) / sec / 1e6 : 0.0,
                mem.rss_mb, mem.peak_mb);
}

void print_csv(const char *name, std::uint64_t units, double sec,
               const MemInfo &mem) {
    std::printf("%s,%" PRIu64 ",%.4f,%.3f,%.1f,%.1f\n", name, units, sec,
                sec > 0.0 ? static_cast<double>(units) / sec / 1e6 : 0.0,
                mem.rss_mb, mem.peak_mb);
}

}  // namespace

int main(int argc, char **argv) {
    Options opt;
    if (!parse_args(argc, argv, opt)) {
        return 2;
    }

    std::printf("=== p1bench ===\n");
    std::printf("build       : %s\n", BENCH_BUILD_TYPE);
    std::printf("compiler    : %s\n", __VERSION__);
    std::printf("libraries   : %s\n              %s\n", cpu_work_name(),
                mem_work_name());
    std::printf("workload    : %.2f s (cpu %d%% / mem %d%%), working set %zu MB,"
                " seed 0x%016" PRIx64 "\n",
                opt.seconds, opt.cpu_pct, 100 - opt.cpu_pct, opt.mem_mb,
                opt.seed);

    if (cpu_work_init(opt.seed) != 0) {
        std::fprintf(stderr, "error: cpu_work_init failed\n");
        return 1;
    }
    if (mem_work_init(opt.mem_mb, opt.seed ^ 0x9E3779B97F4A7C15ull) != 0) {
        std::fprintf(stderr,
                     "error: mem_work_init failed (cannot allocate %zu MB)\n",
                     opt.mem_mb);
        return 1;
    }

    const MemInfo mem_before = read_mem();
    std::printf("rss after init: %.1f MB (peak %.1f MB)\n", mem_before.rss_mb,
                mem_before.peak_mb);

    const Probe cpu_probe = calibrate([](std::uint64_t n) { cpu_work_run(n); });
    const Probe mem_probe = calibrate([](std::uint64_t n) { mem_work_run(n); });

    const double cpu_per_unit =
        cpu_probe.seconds / static_cast<double>(cpu_probe.units);
    const double mem_per_unit =
        mem_probe.seconds / static_cast<double>(mem_probe.units);

    std::printf("calibration : cpu %.2f ns/unit, mem %.2f ns/unit (probe %.0f ms"
                " / %.0f ms)\n",
                cpu_per_unit * 1e9, mem_per_unit * 1e9,
                cpu_probe.seconds * 1e3, mem_probe.seconds * 1e3);

    /* 扣除校准耗时，把剩余预算按比例分给两个库 */
    double remaining =
        opt.seconds - (cpu_probe.seconds + mem_probe.seconds);
    remaining = std::max(remaining, 0.2);

    const std::uint64_t cpu_units = std::max<std::uint64_t>(
        1, static_cast<std::uint64_t>(remaining * (opt.cpu_pct / 100.0) /
                                      cpu_per_unit));
    const std::uint64_t mem_units = std::max<std::uint64_t>(
        1, static_cast<std::uint64_t>(remaining *
                                      ((100 - opt.cpu_pct) / 100.0) /
                                      mem_per_unit));

    const auto t_cpu0 = Clock::now();
    const std::uint64_t cpu_checksum = cpu_work_run(cpu_units);
    const double cpu_sec = seconds_since(t_cpu0);
    const MemInfo mem_after_cpu = read_mem();

    const auto t_mem0 = Clock::now();
    const std::uint64_t mem_checksum = mem_work_run(mem_units);
    const double mem_sec = seconds_since(t_mem0);
    const MemInfo mem_after_mem = read_mem();

    if (opt.leak_mb > 0) {
        mem_work_leak(opt.leak_mb);
    }
    const MemInfo mem_final = read_mem();

    std::printf("\n%-12s %16s %10s %14s %10s %10s\n", "phase", "work units",
                "time [s]", "rate [M/s]", "RSS [MB]", "peak [MB]");
    print_row("cpuwork", cpu_units, cpu_sec, mem_after_cpu);
    print_row("memwork", mem_units, mem_sec, mem_after_mem);

    std::printf("\ntotal measured time : %.3f s\n", cpu_sec + mem_sec);
    std::printf("checksums           : cpu=0x%016" PRIx64 " mem=0x%016" PRIx64
                "\n",
                cpu_checksum, mem_checksum);
    std::printf("peak rss            : %.1f MB\n", mem_final.peak_mb);
    if (opt.leak_mb > 0) {
        std::printf("intentional leak    : %zu MB (not freed, for heaptrack)\n",
                    opt.leak_mb);
    }

    std::printf("\nCSV phase,work_units,seconds,rate_mops,rss_mb,peak_rss_mb\n");
    print_csv("cpuwork", cpu_units, cpu_sec, mem_after_cpu);
    print_csv("memwork", mem_units, mem_sec, mem_after_mem);

    mem_work_shutdown();
    return 0;
}
