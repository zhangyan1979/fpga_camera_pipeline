# =============================================================================
#  restart_app.tcl — reset the PS and let the already-loaded application run
#  again (no bitstream programming, no ELF download).  Handy when only the
#  software changed.   Run:  xsct ps/restart_app.tcl
# =============================================================================
set here [file normalize [file dirname [info script]]]

source [file join $here hw_connect.tcl]
hw_connect

targets -set -filter {name =~ "APU*"}
puts "APU state before reset: [state]"
rst -system
after 500
rst -system
after 2000

targets -set -filter {name =~ "*Cortex-A9*#0"}
con
puts "RESTARTED - the application should print its banner again"
