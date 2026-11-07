#ifndef BM_STATISTICS_H
#define BM_STATISTICS_H
#include <stdint.h>
#include <stdio.h>
typedef struct {
    uint64_t count, pairs, positive[7], negative[7], within[7];
    int64_t minimum_raw, maximum_raw;
    double mean, variance, stddev, pair_correlation, lag1_correlation;
} bm_statistics;
/* Replays from seed for measured-mean intervals; no dynamic allocation. */
int bm_qualify(uint64_t seed, uint64_t count, bm_statistics *out);
void bm_print_statistics(FILE *stream, const bm_statistics *s);
void bm_print_configuration(FILE *stream);
void bm_print_samples(FILE *stream, uint64_t seed);
#endif
