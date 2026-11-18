#include "bench.h"

#include <cstdlib>

namespace {

std::uint64_t *g_data = nullptr;
std::uint64_t g_words = 0;   /* 2 的幂 */
std::uint64_t g_mask = 0;
std::uint64_t g_state = 1;
std::uint64_t g_checksum = 0;

constexpr std::uint64_t kLcgMul = 6364136223846793005ull;
constexpr std::uint64_t kLcgAdd = 1442695040888963407ull;

}  // namespace

extern "C" {

const char *mem_work_name(void) {
    return "libmemwork (random R/W over heap)";
}

void mem_work_shutdown(void) {
    std::free(g_data);
    g_data = nullptr;
    g_words = 0;
    g_mask = 0;
}

int mem_work_init(std::size_t working_set_mb, std::uint64_t seed) {
    mem_work_shutdown();

    if (working_set_mb == 0) {
        working_set_mb = 1;
    }
    const std::size_t bytes = working_set_mb * 1024u * 1024u;
    std::size_t words = bytes / sizeof(std::uint64_t);

    std::size_t pow2 = 1;
    while (pow2 * 2 <= words) {
        pow2 *= 2;
    }
    if (pow2 < 2) {
        return -1;
    }

    void *p = nullptr;
    if (posix_memalign(&p, 64, pow2 * sizeof(std::uint64_t)) != 0) {
        return -1;
    }

    g_data = static_cast<std::uint64_t *>(p);
    g_words = pow2;
    g_mask = pow2 - 1;
    g_state = seed | 1ull;
    g_checksum = 0;

    /* 逐页写入，确保物理内存真正被占用 */
    for (std::uint64_t i = 0; i < g_words; ++i) {
        g_data[i] = i * 0x9E3779B97F4A7C15ull + seed;
    }
    return 0;
}

void mem_work_leak(std::size_t leak_mb) {
    if (leak_mb == 0) {
        return;
    }

    const std::size_t bytes = leak_mb * 1024u * 1024u;
    void *p = nullptr;
    if (posix_memalign(&p, 64, bytes) != 0) {
        return;
    }

    /* 逐页触碰，保证泄漏的内存真实驻留；随后故意不释放 */
    volatile unsigned char *v = static_cast<volatile unsigned char *>(p);
    for (std::size_t i = 0; i < bytes; i += 4096) {
        v[i] = 0xA5;
    }
}

std::uint64_t mem_work_run(std::uint64_t accesses) {
    if (g_data == nullptr) {
        return 0;
    }

    std::uint64_t s = g_state;
    std::uint64_t acc = g_checksum;
    std::uint64_t *const data = g_data;
    const std::uint64_t mask = g_mask;

    for (std::uint64_t i = 0; i < accesses; ++i) {
        s = s * kLcgMul + kLcgAdd;
        const std::uint64_t idx = (s >> 20) & mask;
        const std::uint64_t value = data[idx] + i;
        data[idx] = value;
        acc += value;
    }

    g_state = s;
    g_checksum = acc;
    return acc;
}

}  // extern "C"
