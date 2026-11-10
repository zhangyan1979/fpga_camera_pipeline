# =============================================================================
#  hw_connect.tcl — connect to the on-board JTAG, starting hw_server if needed.
#
#  `connect -url TCP:127.0.0.1:3121` assumes a hw_server is already listening;
#  after a reboot (or when the previous session's server exited) it fails with
#  "Connection refused".  Fall back to a bare `connect`, which starts a local
#  hw_server and connects to it.
# =============================================================================
proc hw_connect {} {
    if {[catch {connect -url TCP:127.0.0.1:3121} msg]} {
        puts "hw_server not listening ($msg) - starting one"
        connect
        after 2000
    }
}
