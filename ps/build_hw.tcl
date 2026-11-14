# =============================================================================
#  build_hw.tcl — Vivado: PS7 (DDR3 + HP0 + FCLK0/GP0) + AXI GPIOs + the camera
#  preview PL top, then bitstream and XSA.  ACZ702 / XC7Z020-CLG400.
#
#  Run:  vivado -mode batch -source ps/build_hw.tcl
#  Out:  ps/build_hw/camera_pipeline.runs/impl_1/design_1_wrapper.bit
#        ps/camera_pipeline.xsa
# =============================================================================
set here   [file normalize [file dirname [info script]]]
set root   [file normalize [file join $here ..]]
set rtl    [file join $root rtl]
set constr [file join $root constr]

create_project camera_pipeline [file join $here build_hw] -part xc7z020clg400-1 -force

# every RTL file in rtl/ is part of the design: adding a processing stage means
# dropping its file in, not editing this list
add_files -norecurse [lsort [glob -nocomplain [file join $rtl *.v]]]

# ---- PS7 with the vendor board preset ---------------------------------------
source [file join $here ps7-preset.tcl]

create_bd_design design_1
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
set_property -dict [apply_preset ps7] [get_bd_cells ps7]
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
] [get_bd_cells ps7]

# ---- control word out, two status words in ----------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_ctrl
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_OUTPUTS {1}] \
    [get_bd_cells axi_gpio_ctrl]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_status
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH  {32} \
    CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_IS_DUAL     {1} \
    CONFIG.C_ALL_INPUTS  {1} \
    CONFIG.C_ALL_INPUTS_2 {1} \
] [get_bd_cells axi_gpio_status]

# the image-processing stage's statistic (see docs/stage_contract.md)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_ext
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1}] \
    [get_bd_cells axi_gpio_ext]

# ---- PL half ----------------------------------------------------------------
create_bd_cell -type module -reference ov5640_top cam_top_0

# the module's AXI4 master runs on clk50 (PS FCLK0); tell the block design,
# otherwise SmartConnect sees the module's default 100 MHz and fails the DRC
set_property CONFIG.FREQ_HZ {50000000} [get_bd_intf_pins cam_top_0/m_axi]

# ---- clocks and reset -------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_50m
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]     [get_bd_pins rst_50m/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst_50m/ext_reset_in]

# ---- AXI-Lite: GP0 -> the two GPIOs -----------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smc_lite
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {3}] [get_bd_cells smc_lite]
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0]    [get_bd_intf_pins smc_lite/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins smc_lite/M00_AXI] [get_bd_intf_pins axi_gpio_ctrl/S_AXI]
connect_bd_intf_net [get_bd_intf_pins smc_lite/M01_AXI] [get_bd_intf_pins axi_gpio_status/S_AXI]
connect_bd_intf_net [get_bd_intf_pins smc_lite/M02_AXI] [get_bd_intf_pins axi_gpio_ext/S_AXI]

# ---- AXI4 master (camera frame buffer engine) -> S_AXI_HP0 ------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smc_hp
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells smc_hp]
connect_bd_intf_net [get_bd_intf_pins cam_top_0/M_AXI] [get_bd_intf_pins smc_hp/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins smc_hp/M00_AXI]  [get_bd_intf_pins ps7/S_AXI_HP0]

# ---- 50 MHz domain wiring ---------------------------------------------------
foreach p {ps7/M_AXI_GP0_ACLK ps7/S_AXI_HP0_ACLK \
           axi_gpio_ctrl/s_axi_aclk axi_gpio_status/s_axi_aclk \
           axi_gpio_ext/s_axi_aclk \
           smc_lite/aclk smc_hp/aclk cam_top_0/clk50} {
    connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins $p]
}
foreach p {axi_gpio_ctrl/s_axi_aresetn axi_gpio_status/s_axi_aresetn \
           axi_gpio_ext/s_axi_aresetn \
           smc_lite/aresetn smc_hp/aresetn} {
    connect_bd_net [get_bd_pins rst_50m/peripheral_aresetn] [get_bd_pins $p]
}
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins cam_top_0/aresetn]

# ---- control and status -----------------------------------------------------
connect_bd_net [get_bd_pins axi_gpio_ctrl/gpio_io_o]  [get_bd_pins cam_top_0/ctrl]
connect_bd_net [get_bd_pins cam_top_0/status_cam]     [get_bd_pins axi_gpio_status/gpio_io_i]
connect_bd_net [get_bd_pins cam_top_0/status_disp]    [get_bd_pins axi_gpio_status/gpio2_io_i]
connect_bd_net [get_bd_pins cam_top_0/status_ext]     [get_bd_pins axi_gpio_ext/gpio_io_i]

assign_bd_address

# ---- external pins ----------------------------------------------------------
set ext_pins {led lcd_bl lcd_pclk lcd_de lcd_hsync lcd_vsync lcd_rgb \
              camera_pclk camera_href camera_vsync camera_xclk camera_data \
              camera_sclk camera_sdat hdmi_sclk hdmi_sdat}
foreach p $ext_pins {
    make_bd_pins_external [get_bd_pins cam_top_0/$p]
}
foreach nm $ext_pins {
    set alt [get_bd_ports -quiet ${nm}_0]
    if {$alt ne ""} { set_property name $nm $alt }
}

validate_bd_design
regenerate_bd_layout
save_bd_design

make_wrapper -files [get_files design_1.bd] -top
set wrapper [glob [file join $here build_hw camera_pipeline.gen sources_1 bd design_1 hdl design_1_wrapper.v]]
add_files -norecurse $wrapper
set_property top design_1_wrapper [current_fileset]
add_files -fileset constrs_1 -norecurse [file join $constr ov5640.xdc]
update_compile_order -fileset sources_1

# ---- build ------------------------------------------------------------------
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "Synthesis failed: [get_property STATUS [get_runs synth_1]]"
}

# the camera PCLK pin is not clock-capable: waive the IOB->BUFG rule on the
# synthesised netlist (see impl_pre.tcl)
set_property STEPS.OPT_DESIGN.TCL.PRE [file join $here impl_pre.tcl] [get_runs impl_1]

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set st [get_property STATUS [get_runs impl_1]]
puts "IMPL STATUS: $st"
if {[string first "write_bitstream Complete!" $st] < 0} {
    error "Implementation failed: $st"
}

open_run impl_1
report_timing_summary -file [file join $here timing_summary.rpt]
report_io            -file [file join $here io_report.rpt]
report_utilization   -file [file join $here utilization.rpt]
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "TIMING wns=$wns whs=$whs"

write_hw_platform -fixed -include_bit -force [file join $here camera_pipeline.xsa]
puts "BITSTREAM [file join $here build_hw camera_pipeline.runs impl_1 design_1_wrapper.bit]"
puts "XSA [file join $here camera_pipeline.xsa]"
close_project
