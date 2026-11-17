# Log all HDL objects under each simulator top, then run to completion.
array set log_seen {}

proc log_scope_tree {scope} {
    global log_seen
    if {[info exists log_seen($scope)]} { return }
    set log_seen($scope) 1

    set objs [get_objects ${scope}/* -quiet]
    if {[llength $objs]} {
        log_wave $objs
    }
    foreach child [get_scopes $scope -quiet] {
        log_scope_tree $child
    }
}

foreach top [get_scopes /] {
    log_scope_tree $top
}

run -all
exit