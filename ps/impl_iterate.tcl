# =============================================================================
#  impl_iterate.tcl — re-run place & route on the existing project (keeps the
#  synthesis result).  Used while iterating; build_hw.tcl is the real flow.
# =============================================================================
set here [file normalize [file dirname [info script]]]
open_project [file join $here build_hw camera_pipeline.xpr]

set_property STEPS.OPT_DESIGN.TCL.PRE [file join $here impl_pre.tcl] [get_runs impl_1]
reset_run impl_1

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set st [get_property STATUS [get_runs impl_1]]
puts "IMPL STATUS: $st"

if {[string first "write_bitstream Complete!" $st] >= 0} {
    open_run impl_1
    report_timing_summary -file [file join $here timing_summary.rpt]
    report_io            -file [file join $here io_report.rpt]
    report_utilization   -file [file join $here utilization.rpt]
    set wns [get_property SLACK [get_timing_paths -delay_type max]]
    set whs [get_property SLACK [get_timing_paths -delay_type min]]
    puts "TIMING wns=$wns whs=$whs"
    write_hw_platform -fixed -include_bit -force [file join $here camera_pipeline.xsa]
    puts "XSA written"
}
close_project
