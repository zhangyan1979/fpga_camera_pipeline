# =============================================================================
#  dump_fb.tcl — read a live DDR frame buffer out over JTAG.
#
#  Run:  xsct ps/dump_fb.tcl [buffer]        buffer = 0 (default) or 1
#
#  Writes ps/fb_dump.bin (768 000 bytes, RGB565).  Render it with
#      python tools/fb2png.py ps/fb_dump.bin docs/frame.png
# =============================================================================
set here [file normalize [file dirname [info script]]]

set buf 0
if {[llength $argv] >= 1} { set buf [lindex $argv 0] }

set fb [expr {0x01800000 + $buf * 768000}]
set words [expr {768000 / 4}]
set out [file join $here fb_dump.bin]

source [file join $here hw_connect.tcl]
hw_connect

targets -set -filter {name =~ "APU*"}
after 200
stop
after 100
mrd -bin -file $out $fb $words
con
puts "DUMPED buffer $buf @ [format 0x%08X $fb] -> $out ($words words)"
