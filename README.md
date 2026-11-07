# awgn_generator
FPGA based AWGN generator using Box Muller

## Synthesizable implementation

`src/bm_axis_rtl.vhd` exposes the same generics and AXI Stream ports as
`bm_axis_behavioral`. Compile `src/bm_rtl_constants_pkg.vhd` and
`src/bm_rtl_pkg.vhd` first, then the functional blocks `src/bm_log.vhd`,
`src/bm_sqrt.vhd`, `src/bm_trig.vhd`, and `src/bm_products.vhd`, followed by
`src/bm_axis_rtl.vhd` and its wrapper. The RTL does not use the behavioral
packages. The blocks share `bm_config_t` and `bm_token_t` from `bm_rtl_pkg`.

`bm_log` owns U1 normalization and the logarithmic pipeline; `bm_sqrt` adapts
its input, extracts the root, and rounds the radius. `bm_trig` computes the
parallel phase branch. `bm_products` applies the quadrant, multiplies, and
converts the output format. `bm_axis_rtl` retains the PRNG, stream control,
serializer, cached sample, and branch alignment. Each block uses the same
clock, synchronous active-low reset, and global `advance` enable.

An input beat is an unsigned 32-bit sample count. A zero count does nothing.
Only one command is active at a time. The output contains signed fixed-point
samples, sign extended to a whole number of bytes. The binary point is set by
`BM_OUTPUT_FRAC_BITS`.

The logarithm and integer square root form one registered branch; sine/cosine
form a parallel registered branch. Each CORDIC/root iteration has its own
register stage. Alignment registers join the branches before the products and
output conversion. One pair is launched every two enabled clocks and serialized
as `z0`, then `z1`, giving one output sample per clock after pipeline fill when
the receiver remains ready. Initial latency and gaps between commands are
allowed. An unused `z1` is retained across odd-sized commands and travels through
the pipeline at the start of the next command to preserve continuous output
within that command.

Backpressure freezes the pipeline and serializer together. Reset is active low
and synchronous; it clears all registers and restores the configured PRNG seed.
There are no signal declaration initializers or variable declarations in `src/`.
The design uses portable numeric_std arithmetic and inferrable multipliers;
frequency, DSP mapping, and resource usage require synthesis on the target FPGA.

`sim/run_bm_axis_behavioral_tb.py` runs only the behavioral testbench.
`sim/run_bm_axis_rtl_tb.py` runs only `tb/bm_axis_rtl_tb.vhd`, including the
behavioral sources needed as its reference.
The RTL tests compare accepted samples against the independent behavioral model,
check continuous throughput and stability under backpressure, and cover null,
odd/even successive commands and reset during operation. Configurations cover
32/64-bit PRNGs, rounding, and overflow modes. The default configuration also
compares the first 100 integers in `model/samples_raw.txt`; other configurations
use the behavioral reference because that file represents the default settings.
These tests are provided for execution by the user; no compilation, simulation,
or synthesis was performed while adding the RTL.
