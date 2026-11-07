# Gaussian histogram analyzer

`bm_histogram_axi` exposes a 32-bit AXI4-Lite slave with 12-bit byte addresses,
independent AW/W handshakes, byte write strobes, one buffered write and one
outstanding read. AWPROT/ARPROT are accepted and ignored. All logic uses `aclk`
and a synchronous active-low `aresetn`. The generator's AXI Stream ports are
internal. All `BM_*` generics are passed through unchanged.

## Measurement semantics

The inspected generator accepts one 32-bit sample-count command, emits one
signed sample per output transfer and accepts the next command after the last
sample transfers. N counts samples, not Box-Muller pairs. Its global advance
enable preserves output VALID/data and freezes the pipeline under backpressure.
An unused partner of an odd command is cached for the next command. There is
no externally exposed FIFO; pipeline/serializer state belongs to the generator.

* START (CONTROL=1) captures N_SAMPLES, resets the generator for one clock to
  restore its configured seed and discard any cached partner, sequentially
  clears all results, then acquires exactly N samples. Repeated START operations
  reproduce the same sequence for identical configuration and N.
* CONTINUE (CONTROL=2) captures N_SAMPLES and preserves PRNG, cached partner,
  histogram and statistics. Each command supports 1 through 0xFFFFFFFF samples;
  successive commands can accumulate billions of samples using 64-bit counts.
* CLEAR (CONTROL=4) erases results without changing the PRNG/cache or generating
  samples. A later CONTINUE resumes the sequence with statistics starting at zero.
* Reset aborts acquisition, resets the PRNG and automatically clears BRAM.
  Software must wait for BUSY=0 before sending a command, including after reset.

BUSY covers initialization, memory clear, command handshake, acquisition and
pending histogram writes. DONE is set only when N samples have transferred,
updates have committed and the generator is ready for another command. DONE
remains set until reset or another accepted command. CLEAR returns with DONE=0.
N_SAMPLES can be edited during BUSY; the current acquisition uses its captured N.

Commands during BUSY, conflicting bits, START/CONTINUE with N=0, invalid register
accesses and invalid bin addresses return SLVERR and set sticky ERROR. CONTROL=0
and masked-off command bytes are no-ops. A new accepted command clears ERROR;
CONTINUE reasserts it if COUNTER_OVERFLOW is already set. Errors do not interrupt
an acquisition or discard its samples. Unexpected generator VALID outside the
acquisition state also sets ERROR. There is no timeout or automatic recovery for
a malfunctioning generator: reset recovers a hung acquisition.

## Register map

All offsets are byte offsets, naturally aligned to 32 bits. Responses are OKAY
(00) or SLVERR (10). Reads of CONTROL and writes to read-only registers fail.
Unknown/unaligned addresses fail. WSTRB controls each byte of writable registers;
bits reserved in CONTROL and BIN_ADDR must be zero in the effective written value.

| Offset | Name | Access |
| --- | --- | --- |
| 0x000 | CONTROL: bit 0 START, bit 1 CONTINUE, bit 2 CLEAR (write-one commands) | W |
| 0x004 | STATUS: bit 0 BUSY, 1 DONE, 2 ERROR, 3 CLEARING, 4 COUNTER_OVERFLOW | R |
| 0x008 | N_SAMPLES (reset value zero) | RW |
| 0x00C / 0x010 | TOTAL_COUNT low / high | R |
| 0x014 | BIN_ADDR (reset value zero) | RW |
| 0x018 / 0x01C | BIN_COUNT low / high | R |
| 0x020 / 0x024 | UNDERFLOW low / high | R |
| 0x028 / 0x02C | OVERFLOW low / high | R |
| 0x030 / 0x034 | TAIL_POS_3 low / high | R |
| 0x038 / 0x03C | TAIL_POS_4 low / high | R |
| 0x040 / 0x044 | TAIL_POS_5 low / high | R |
| 0x048 / 0x04C | TAIL_POS_6 low / high | R |
| 0x050 / 0x054 | TAIL_POS_7 low / high | R |
| 0x058 / 0x05C | TAIL_NEG_3 low / high | R |
| 0x060 / 0x064 | TAIL_NEG_4 low / high | R |
| 0x068 / 0x06C | TAIL_NEG_5 low / high | R |
| 0x070 / 0x074 | TAIL_NEG_6 low / high | R |
| 0x078 / 0x07C | TAIL_NEG_7 low / high | R |

STATUS reserved bits read as zero. ERROR is cleared on an accepted command or
reset. COUNTER_OVERFLOW is sticky across CONTINUE, and cleared by START, CLEAR
or reset. Every counter saturates at its configured maximum instead of wrapping;
acquisition still completes. Counter saturation sets both overflow status and
ERROR, so software must reject saturated results for conservation checks.

## Coherent software reads

For each statistical counter, read its low word first: that read captures the
whole 64-bit value. Read the high word from the same counter next and combine
`(uint64_t(high) << 32) | low`. These snapshots are independent per counter and
remain valid until their next low read, an accepted command, or reset. A high
read without a valid snapshot fails. Individual counters can be read while BUSY,
but their independent snapshots do not constitute a global simultaneous snapshot.
Wait for BUSY=0 for a mutually consistent set of final results.

For bins, wait for BUSY=0, write BIN_ADDR, read BIN_COUNT_L, then BIN_COUNT_H.
The low read performs a synchronous BRAM access and captures both halves. A bin
address write invalidates its snapshot. Bin reads while BUSY fail. A previously
accepted memory read finishes its capture before a new command or address write
executes. AXI RDATA remains stable even if a later command starts while RREADY=0.
Software should serialize command writes with its own multiword read sequences.

Example acquisition sequence:

```text
wait until (read32(STATUS) & BUSY) == 0
write32(N_SAMPLES, 10000)
write32(CONTROL, START)
wait until (read32(STATUS) & BUSY) == 0
require DONE == 1 and ERROR == 0 and COUNTER_OVERFLOW == 0
read TOTAL_COUNT low, then high
for bin in 0..1023:
    write32(BIN_ADDR, bin)
    read BIN_COUNT low, then high
write32(N_SAMPLES, next_count)
write32(CONTROL, CONTINUE)
```

## Histogram bins and sigma intervals

With the default 1024 bins covering `[-8 sigma, +8 sigma)`, each bin spans
`16/1024 = 1/64 = 0.015625 sigma`. The lower boundary is included and the upper
boundary is excluded. For bin index `i` (0 through 1023):

```text
lower edge = -8 + i/64
upper edge = -8 + (i+1)/64
bin center = -8 + (i+0.5)/64
```

All these values are in sigma units. Conversely, for a sample `Z` in `[-8,+8)`:

```text
bin = floor(64 * (Z + 8))
```

| Bin | Interval in sigma units |
| --- | --- |
| 0 | [-8, -7.984375) |
| 320 | [-3, -2.984375) |
| 511 | [-0.015625, 0) |
| 512 | [0, +0.015625) |
| 704 | [+3, +3.015625) |
| 1023 | [+7.984375, +8) |

Samples below -8 go to UNDERFLOW; samples at or above +8 go to OVERFLOW.
Sigma refers to the theoretical standard-normal unit, not the standard deviation
measured from the acquired samples. A bin contains occurrences within its
interval, not the cumulative count beyond a sigma threshold; use the dedicated
tail counters for strict threshold exceedances.

For a different histogram depth `D = 2**HIST_ADDR_BITS`, replace `1/64` by
`16/D`: bin `i` covers `[-8 + 16*i/D, -8 + 16*(i+1)/D)`.

## Histogram datapath and synthesis

The fixed amplitude range is [-8,+8). At the default Q18 output format and 1024
bins, bin = floor((raw + 8*2^18)/4096). The implementation compares extended
signed values first, then uses shifts and bit extraction. -8 belongs to bin 0;
+8 is overflow. Values outside the range are never clamped. Every accepted
sample increments exactly one bin, UNDERFLOW or OVERFLOW, plus TOTAL_COUNT.
Tail counters independently compare strictly against +3 through +7 and -3
through -7 in fixed-point units, matching the C qualification convention.

`HIST_ADDR_BITS` supports 4..10 (16..1024 bins). `COUNTER_BITS` supports 1..64,
with zero-extended 64-bit software readback. Defaults are 1024 bins and 64 bits.
The engine supports binary points from 0..48 and sample widths through 64 bits;
the wrapper additionally inherits the existing generator's configuration checks.
A coarse output format may make some bins unreachable; changing the binary
point changes mapping automatically without floating-point arithmetic.

`bm_histogram_engine` infers a single-clock synchronous simple dual-port memory
with one read port and one write port. Default capacity is 65536 bits. Memory
words and RAM output are not reset. Initialization/clear writes one zero per
clock for 1024 clocks by default, plus controller overhead. The pipeline accepts
one sample per clock, including repeated bins. It forwards both the newest
pending write and the immediately preceding committed write, covering RAW
hazards and read-during-write ambiguity without relying on a device-specific
collision mode. Final completion waits for both update and write stages to empty.
Only the small statistical register array uses synchronous reset.

Compile packages and functional generator blocks before the generator, followed
by `bm_histogram_engine` and `bm_histogram_axi`. The existing Quartus source list
includes the new modules and preserves `bm_axis_rtl_wrapper` as its top level.
To synthesize the analyzer, select `bm_histogram_axi` as TOP_LEVEL_ENTITY in a
separate project/revision or update the assignment yourself. AXI clock/reset,
pins and timing constraints must be supplied for the target integration.

BRAM inference, resource use and timing have not been confirmed by synthesis.
A 64-bit increment, comparisons and bypass muxes may limit Fmax; no frequency
claim is made. The generator's existing PRNG/output configuration limits still
apply. In particular, finite U1 resolution bounds the available Gaussian radius:
with 32-bit U1 the ideal bound is sqrt(64*ln(2)), approximately 6.66, before
fixed-point approximation effects. A zero 7-sigma counter at that configuration
does not qualify a physical 7-sigma tail. The analyzer does not extend the
underlying generator distribution. N_SAMPLES is 32-bit per command, and results
saturate at 64 bits by default.

## Tests supplied, not executed

`sim/run_bm_histogram_axi_tb.py` registers VHDL-1993 RTL and VHDL-2008 VUnit tests.
It provides deterministic engine tests, narrow-counter saturation, a 16-bin configuration and a coarse
binary-point configuration exercising left-shift mapping. Engine stimuli cover
all default bin boundaries, strict thresholds, repeated/alternating/random
addresses, no-gap updates, clear and a sample held until ready returns.

The AXI testbench instantiates the actual RTL analyzer and an independent
behavioral generator as the numerical reference. It checks every bin and tail
counter after 10000-sample acquisitions, successive CONTINUE commands, repeated
START including odd commands, CLEAR and reset during measurement. Protocol tests
cover separated AW/W arrivals, WSTRB, held B/R responses, illegal accesses,
snapshot invalidation, BRAM-read/command serialization and wrapper overflow
status persistence/recovery using reduced-width counters.

For later user execution:

```text
python sim/run_bm_histogram_axi_tb.py
```

No compilation, elaboration, simulation or synthesis was run while implementing
this feature, as requested. These are proposed self-checking tests, not passing
simulation results. The existing RTL tests remain available separately to test
generator backpressure directly.


### Follow a single 10000-sample acquisition in verbose mode

```text
python sim/run_bm_histogram_axi_tb.py -v "lib.bm_histogram_axi_tb.prng64.acquire_10000_samples_and_dump_ram"
```

The `acquire_10000_samples_and_dump_ram` testcase performs one START for 10000
samples with the real AWGN RTL. Messages prefixed `[10000]` show the command,
STATUS transitions, acquisition progress, completed counting and the complete
1024-bin RAM readback through AXI4-Lite. Each bin is logged, including zeros,
with its 64-bit hexadecimal count and expected decimal count. It also logs the
statistical counters by register offset and checks the conservation sum against
TOTAL_COUNT=10000. The independent behavioral model supplies expected values.
The same testcase is registered as `prng32` for the 32-bit PRNG configuration.
This command is provided for user execution; it was not run during the edit.
