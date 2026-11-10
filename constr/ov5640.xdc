# =============================================================================
#  ov5640.xdc — ACZ702 + OV5640 camera header + 800x480 TFT, RGB565
#
#  The panel timings and pins are the ones the vendor tutorials use:
#  1056 x 526 @ 33.333 MHz (60.0 Hz), HSYNC/VSYNC negative, DE active high.
#  The camera side is the dedicated DVP header (M17 PCLK, ~42 MHz).
#  No external clock pin: the PL clock is PS FCLK0.
# =============================================================================

# ---- board LED and panel backlight -----------------------------------------
set_property PACKAGE_PIN T14 [get_ports led]
set_property IOSTANDARD  LVCMOS33 [get_ports led]

set_property PACKAGE_PIN R17 [get_ports lcd_bl]
set_property IOSTANDARD  LVCMOS33 [get_ports lcd_bl]

# ---- panel RGB interface -----------------------------------------------------
set_property PACKAGE_PIN U15 [get_ports lcd_pclk]
set_property IOSTANDARD  LVCMOS33 [get_ports lcd_pclk]
set_property PACKAGE_PIN W15 [get_ports lcd_de]
set_property IOSTANDARD  LVCMOS33 [get_ports lcd_de]
set_property PACKAGE_PIN U14 [get_ports lcd_hsync]
set_property IOSTANDARD  LVCMOS33 [get_ports lcd_hsync]
set_property PACKAGE_PIN W14 [get_ports lcd_vsync]
set_property IOSTANDARD  LVCMOS33 [get_ports lcd_vsync]

# lcd_rgb[15:11] = R4..R0, [10:5] = G5..G0, [4:0] = B4..B0
set_property PACKAGE_PIN W20 [get_ports {lcd_rgb[15]}]
set_property PACKAGE_PIN W19 [get_ports {lcd_rgb[14]}]
set_property PACKAGE_PIN V17 [get_ports {lcd_rgb[13]}]
set_property PACKAGE_PIN V16 [get_ports {lcd_rgb[12]}]
set_property PACKAGE_PIN T15 [get_ports {lcd_rgb[11]}]
set_property PACKAGE_PIN V20 [get_ports {lcd_rgb[10]}]
set_property PACKAGE_PIN U17 [get_ports {lcd_rgb[9]}]
set_property PACKAGE_PIN V18 [get_ports {lcd_rgb[8]}]
set_property PACKAGE_PIN T16 [get_ports {lcd_rgb[7]}]
set_property PACKAGE_PIN R16 [get_ports {lcd_rgb[6]}]
set_property PACKAGE_PIN U19 [get_ports {lcd_rgb[5]}]
set_property PACKAGE_PIN Y19 [get_ports {lcd_rgb[4]}]
set_property PACKAGE_PIN W18 [get_ports {lcd_rgb[3]}]
set_property PACKAGE_PIN Y18 [get_ports {lcd_rgb[2]}]
set_property PACKAGE_PIN W16 [get_ports {lcd_rgb[1]}]
set_property PACKAGE_PIN Y17 [get_ports {lcd_rgb[0]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {lcd_rgb[*]}]

# source-synchronous RGB output: constrain the data/sync pins against a virtual
# clock of the same period instead of the internal MMCM net
create_clock -name lcd_pclk_virt -period 30.000
set_output_delay -clock lcd_pclk_virt -max 12.000 \
    [get_ports {lcd_rgb[*] lcd_de lcd_hsync lcd_vsync}]
set_output_delay -clock lcd_pclk_virt -min 0.000 \
    [get_ports {lcd_rgb[*] lcd_de lcd_hsync lcd_vsync}]

# ---- OV5640 DVP header -------------------------------------------------------
set_property PACKAGE_PIN M17 [get_ports camera_pclk]
set_property PACKAGE_PIN U13 [get_ports camera_href]
set_property PACKAGE_PIN N16 [get_ports camera_vsync]
set_property PACKAGE_PIN A20 [get_ports camera_xclk]
set_property IOSTANDARD  LVCMOS33 [get_ports {camera_pclk camera_href camera_vsync camera_xclk}]

set_property PACKAGE_PIN L16 [get_ports {camera_data[7]}]
set_property PACKAGE_PIN L17 [get_ports {camera_data[6]}]
set_property PACKAGE_PIN K17 [get_ports {camera_data[5]}]
set_property PACKAGE_PIN M15 [get_ports {camera_data[4]}]
set_property PACKAGE_PIN L14 [get_ports {camera_data[3]}]
set_property PACKAGE_PIN N15 [get_ports {camera_data[2]}]
set_property PACKAGE_PIN M14 [get_ports {camera_data[1]}]
set_property PACKAGE_PIN J15 [get_ports {camera_data[0]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {camera_data[*]}]

# camera I2C (SCCB)
set_property PACKAGE_PIN N17 [get_ports camera_sclk]
set_property PACKAGE_PIN P18 [get_ports camera_sdat]
set_property IOSTANDARD  LVCMOS33 [get_ports {camera_sclk camera_sdat}]
set_property PULLUP true [get_ports camera_sdat]

# PCLK (M17) is not a clock-capable pin, so the IOB -> BUFG route needs
# CLOCK_DEDICATED_ROUTE FALSE on the IBUF net.  That net only exists in the
# synthesised netlist, and XDC files do not allow Tcl conditionals, so the
# waiver lives in ps/impl_pre.tcl (hooked into the implementation run).

create_clock -name camera_pclk -period 23.810 [get_ports camera_pclk]
set_clock_groups -asynchronous -group [get_clocks camera_pclk]

# ---- HDMI transmitter I2C (PL I2C bus, SiI9022A) -----------------------------
set_property PACKAGE_PIN T10 [get_ports hdmi_sclk]
set_property PACKAGE_PIN R14 [get_ports hdmi_sdat]
set_property IOSTANDARD  LVCMOS33 [get_ports {hdmi_sclk hdmi_sdat}]
set_property PULLUP true [get_ports hdmi_sdat]
