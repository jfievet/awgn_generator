#ifndef FIXED_MATH_H
#define FIXED_MATH_H
#include <stdint.h>
/* Width arguments: 1..63. Fractions/shifts: 0..63. */
uint64_t fm_mask(unsigned bits);
int64_t fm_asr(int64_t value, unsigned shift);
int64_t fm_wrap(int64_t value, unsigned bits);
int64_t fm_signed(int64_t value, unsigned bits, int overflow);
uint64_t fm_unsigned(uint64_t value, unsigned bits, int overflow);
int64_t fm_scale(int64_t value, unsigned from, unsigned to, unsigned bits, int rounding, int overflow);
uint64_t fm_uscale(uint64_t value, unsigned from, unsigned to, unsigned bits, int rounding, int overflow);
/* Q60 table -> chosen constant precision -> destination precision (nearest). */
uint64_t fm_constant(uint64_t q60, unsigned constant_frac, unsigned destination_frac);
#endif
