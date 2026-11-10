# =============================================================================
#  hw_connect.tcl — connect to the on-board JTAG, starting hw_server if needed.
#
#  `connect -url TCP:127.0.0.1:3121` assumes a hw_server is already listening;
#  after a reboot (or when the previous session's server exited) it fails with
#  "Connection refused".  Fall back to a bare `connect`, which starts a local
#  hw_server and connects to it.
#
#  A hw_server left over from an earlier session can keep a dead handle on the
#  cable: every command then "succeeds" but nothing happens (the FPGA is not
#  reprogrammed, the CPU is not reset, the ELF is not re-downloaded).  Killing
#  any stale server first makes every run deterministic.
# =============================================================================
proc hw_connect {} {
    catch {exec cmd /c {taskkill /F /IM hw_server.exe >NUL 2>&1}}
    after 500

    if {[catch {connect -url TCP:127.0.0.1:3121} msg]} {
        puts "hw_server not listening ($msg) - starting one"
        connect
        after 3000
    }
}
