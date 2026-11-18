#ifndef P1BENCH_BENCH_H
#define P1BENCH_BENCH_H

#include <cstddef>
#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------- libcpuwork.so：CPU 密集型负载 ---------------- */

const char *cpu_work_name(void);
int cpu_work_init(std::uint64_t seed);
/* 执行 iterations 次固定的整数/浮点运算，返回校验和 */
std::uint64_t cpu_work_run(std::uint64_t iterations);

/* ---------------- libmemwork.so：内存密集型负载 ---------------- */

const char *mem_work_name(void);
/* 分配 working_set_mb 的堆内存并初始化，失败返回非 0 */
int mem_work_init(std::size_t working_set_mb, std::uint64_t seed);
/* 在堆内存上执行 accesses 次随机读-改-写，返回校验和 */
std::uint64_t mem_work_run(std::uint64_t accesses);
/* 故意泄漏 leak_mb 兆内存（不释放），仅用于演示 heaptrack 泄漏火焰图 */
void mem_work_leak(std::size_t leak_mb);
void mem_work_shutdown(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* P1BENCH_BENCH_H */
