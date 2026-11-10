# =============================================================================
#  build_app.tcl — Vitis classic (XSCT) flow: platform from the XSA, BSP, the
#  bare-metal application, and a build.
#
#  Run:  xsct ps/build_app.tcl
#  Out:  ps/vitis_ws/ov5640_preview/Debug/ov5640_preview.elf
#
#  `app build` builds the platform and BSP; on some 2023.2 installs it stops
#  before compiling the application, so the script falls back to running the
#  generated makefile with the Vitis toolchain on PATH.
# =============================================================================
set here [file normalize [file dirname [info script]]]

file delete -force [file join $here vitis_ws]
setws [file join $here vitis_ws]

createhw  -name hw  -hwspec [file join $here ov5640_preview.xsa]
createbsp -name bsp -hw hw -proc ps7_cortexa9_0
createapp -name ov5640_preview -hw hw -bsp bsp -proc ps7_cortexa9_0 -app "Empty Application"

foreach f {main.c} {
    file copy -force [file join $here app $f] \
                     [file join $here vitis_ws ov5640_preview src $f]
}

app build ov5640_preview

set elf [file join $here vitis_ws ov5640_preview Debug ov5640_preview.elf]
if {![file exists $elf]} {
    puts "app build did not produce the ELF - running the generated makefile"
    set vitis_root "D:/Xilinx/Vitis/2023.2"
    set env(PATH) [join [list \
        [file join $vitis_root gnuwin bin] \
        [file join $vitis_root gnu aarch32 nt gcc-arm-none-eabi bin] \
        $env(PATH)] ";"]
    cd [file join $here vitis_ws ov5640_preview Debug]
    if {[catch {exec make all 2>@1} out]} {
        puts $out
        error "app build failed"
    }
    puts $out
}

if {![file exists $elf]} {
    error "app build failed: $elf was not produced"
}
puts "APP BUILD DONE $elf"
