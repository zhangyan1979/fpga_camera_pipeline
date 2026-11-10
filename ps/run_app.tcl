# =============================================================================
#  run_app.tcl — program the bitstream and start the application over the
#  on-board JTAG.   Run:  xsct ps/run_app.tcl
#
#  Leave the boot-mode DIP switch in the JTAG position (MIO4/MIO5 up/up).
# =============================================================================
set here [file normalize [file dirname [info script]]]

source [file join $here hw_connect.tcl]
hw_connect

# a double reset is harmless and makes the sequence reliable when the previous
# application is still running (the first rst can be swallowed by a stale target)
targets -set -filter {name =~ "APU*"}
rst -system
after 500
rst -system
after 3000

targets -set -filter {name =~ "xc7z020"}
fpga -file [file join $here build_hw camera_pipeline.runs impl_1 design_1_wrapper.bit]

targets -set -filter {name =~ "*Cortex-A9*#0"}
source [file join $here vitis_ws hw hw ps7_init.tcl]
ps7_init
ps7_post_config

dow [file join $here vitis_ws camera_pipeline Debug camera_pipeline.elf]
con
puts "RUNNING - the panel should show the camera picture"
