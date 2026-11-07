"""VUnit entry point; run explicitly to compile/simulate the histogram tests."""
from pathlib import Path
from vunit import VUnit

ROOT = Path(__file__).resolve().parent.parent
VU = VUnit.from_argv()
VU.add_vhdl_builtins()
LIB = VU.add_library("lib")

# Synthesizable sources intentionally checked in VHDL-1993 mode.
for name in (
    "bm_rtl_constants_pkg", "bm_rtl_pkg", "bm_log", "bm_sqrt", "bm_trig",
    "bm_products", "bm_axis_rtl", "bm_histogram_engine", "bm_histogram_axi",
):
    LIB.add_source_files(ROOT / "src" / f"{name}.vhd", vhdl_standard="93")

# The independent reference and VUnit testbenches use VHDL-2008.
for name in ("bm_constants_pkg", "bm_behavioral_pkg", "bm_axis_behavioral"):
    LIB.add_source_files(ROOT / "tb" / "model" / f"{name}.vhd", vhdl_standard="2008")
for name in ("bm_histogram_engine_tb", "bm_histogram_axi_tb"):
    LIB.add_source_files(ROOT / "tb" / f"{name}.vhd", vhdl_standard="2008")

ENGINE = LIB.test_bench("bm_histogram_engine_tb")
ENGINE.add_config(name="default", generics={"counter_bits": 64, "frac_bits": 18})
ENGINE.add_config(name="saturation", generics={"counter_bits": 8, "frac_bits": 18})
ENGINE.add_config(name="left_shift_mapping", generics={"counter_bits": 64, "frac_bits": 4})
ENGINE.add_config(name="small_histogram", generics={"counter_bits": 1, "frac_bits": 12, "hist_addr_bits": 4})
AXI = LIB.test_bench("bm_histogram_axi_tb")
for test_name in ("acquire_10000_samples_and_dump_ram", "axi_protocol_and_errors", "measurements_and_reference", "readback_command_serialization"):
    for bits in (64, 32):
        AXI.test(test_name).add_config(name=f"prng{bits}", generics={"prng_bits": bits})
AXI.test("counter_saturation").add_config(name="full_width", generics={"counter_bits": 64})
AXI.test("counter_saturation").add_config(name="narrow", generics={"counter_bits": 8})

VU.main()
