#ifndef CORDIC_LOG_H
#define CORDIC_LOG_H
#include <stdint.h>
/* u / 2^BM_U1_BITS, u=0 follows the same mapping as u=1. */
uint64_t bm_log(uint64_t u);
unsigned bm_log_last_shift(void);
#endif
