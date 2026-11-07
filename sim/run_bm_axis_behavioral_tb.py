#Running with VUNIT revision from 21/12/2024 12:22:36 AM - SHA-1: 95f5959ea2a6b72d3cb3e774c5f6ae263832b512

from pathlib import Path
from vunit import VUnit

ROOT = Path(__file__).parent / "../"

# Call Vunit addons
VU = VUnit.from_argv()
VU.add_vhdl_builtins()
VU.add_verification_components()

# Source files
LIB = VU.add_library("lib")
LIB.add_source_files(ROOT / "tb" / "model" / "bm_constants_pkg.vhd", vhdl_standard="2008")
LIB.add_source_files(ROOT / "tb" / "model" / "bm_behavioral_pkg.vhd", vhdl_standard="2008")
LIB.add_source_files(ROOT / "tb" / "model" / "bm_axis_behavioral.vhd", vhdl_standard="2008")
LIB.add_source_files(ROOT / "tb" / "bm_axis_behavioral_tb.vhd", vhdl_standard="2008")
LIB.test_bench("bm_axis_behavioral_tb").set_generic(
    "samples_file", (ROOT / "model" / "samples_raw.txt").resolve().as_posix()
)
# Modelsim options
#VU.set_sim_option('modelsim.init_files.after_load', [str(ROOT / 'sim' / 'wave_axi_soc_subsystem_tb.do')])
#VU.set_sim_option('modelsim.vsim_flags', ["-voptargs=\"+acc\""])

VU.main()
