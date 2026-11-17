# Re-synthesize the camera top after a menu change and write a new bitstream.
# The block design is unchanged, so this skips recreating the project.
set here [file normalize [file dirname [info script]]]
open_project [file join $here build_hw camera_pipeline.xpr]

reset_run design_1_cam_top_0_0_synth_1
reset_run synth_1
set_property STEPS.OPT_DESIGN.TCL.PRE [file join $here impl_pre.tcl] [get_runs impl_1]

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set st [get_property STATUS [get_runs impl_1]]
puts "IMPL STATUS: $st"
if {[string first "write_bitstream Complete!" $st] < 0} {
    error "Implementation failed: $st"
}

open_run impl_1
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "TIMING wns=$wns whs=$whs"
write_hw_platform -fixed -include_bit -force [file join $here camera_pipeline.xsa]
puts "XSA written"
close_project
