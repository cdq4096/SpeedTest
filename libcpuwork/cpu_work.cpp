#include "bench.h"

#include <cmath>

namespace {

std::uint64_t g_state = 0x9E3779B97F4A7C15ull;
std::uint64_t g_checksum = 0;

inline std::uint64_t xorshift64(std::uint64_t &x) {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

}  // namespace

extern "C" {

const char *cpu_work_name(void) {
    return "libcpuwork (integer mix + sqrt)";
}

int cpu_work_init(std::uint64_t seed) {
    g_state = seed ? seed : 0x9E3779B97F4A7C15ull;
    g_checksum = 0;
    return 0;
}

std::uint64_t cpu_work_run(std::uint64_t iterations) {
    std::uint64_t s0 = g_state;
    std::uint64_t s1 = g_checksum + 0xD1B54A32D192ED03ull;
    double acc = 0.0;

    for (std::uint64_t i = 0; i < iterations; ++i) {
        const std::uint64_t r = xorshift64(s0);
        s1 += r * 0x2545F4914F6CDD1Dull;
        const std::uint64_t mixed =
            (s1 ^ (s1 >> 29)) * 0xBF58476D1CE4E5B9ull;
        acc += std::sqrt(static_cast<double>(mixed & 0xFFFFFull) + 1.0);
    }

    g_state = s0;
    g_checksum = s1 + static_cast<std::uint64_t>(acc);
    return g_checksum;
}

}  // extern "C"
