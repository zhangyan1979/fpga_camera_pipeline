# =============================================================================
#  impl_pre.tcl — runs inside the implementation run, right before opt_design.
#
#  The OV5640 pixel clock arrives on M17, which is not a clock-capable (CCIO)
#  pin, so the IOB -> BUFG route is not a dedicated clock route.  The vendor
#  reference design waives the same rule; 42 MHz over the general fabric is
#  fine.  The constraint has to be set on the IBUF net, which only exists once
#  the netlist is loaded - hence this hook instead of a plain XDC line.
# =============================================================================
set nets [get_nets -hierarchical -quiet -filter {NAME =~ "*camera_pclk_IBUF*"}]
if {[llength $nets] > 0} {
    set_property CLOCK_DEDICATED_ROUTE FALSE $nets
    puts "IMPL PRE: CLOCK_DEDICATED_ROUTE FALSE on $nets"
} else {
    puts "IMPL PRE: no camera_pclk IBUF net found"
}
