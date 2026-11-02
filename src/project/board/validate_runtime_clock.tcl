# Reuse the finished physical routing, with a lower, software-enforced PS PL0 clock.
# runtime_args.tcl records the original DCP/HWH paths and actual runtime period.
source runtime_args.tcl
open_checkpoint $source_checkpoint
set clk [get_clocks clk_pl_0]
if {[llength $clk]!=1} {error "Expected one PS PL0 clock"}
set pins [get_property SOURCE_PINS $clk]
if {[llength $pins]!=1} {error "Expected one PS clock source pin"}
create_clock -name clk_pl_0 -period $runtime_period [get_pins $pins]
report_timing_summary -file timing_routed.rpt
report_utilization -file utilization_routed.rpt
report_drc -file drc_routed.rpt
report_route_status -file route_status.rpt
set setup_paths [get_timing_paths -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup_paths]==0 || [llength $hold_paths]==0} {error "Missing timing paths"}
foreach path [concat $setup_paths $hold_paths] {
    if {[get_property SLACK $path]<0} {error "Runtime clock timing failed"}
}
puts "RUNTIME_CLOCK_OVERRIDE_REQUIRED: PYNQ driver must set PL0 to $runtime_mhz MHz before starting any task. HWH nominal clock remains 100 MHz."
file mkdir export
write_bitstream -force export/spmm_zcu104.bit
file copy -force $source_hwh export/spmm_zcu104.hwh
puts "ZCU104_RUNTIME_CLOCK_PASS"
