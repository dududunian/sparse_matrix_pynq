# Start in a fresh Vivado 2018.3 GUI session, using an absolute source path.
# This script builds hardware locally and never connects to the board.
set pkg [file dirname [file normalize [info script]]]
set work_root [file normalize [file join $pkg .. run_work]]
if {[info exists ::env(NS_WORK_DIR)]} {set work_root $::env(NS_WORK_DIR)}
file mkdir $work_root
set ::env(TEMP) $work_root
set ::env(TMP) $work_root
if {[info exists ::env(NS_BUILD_DIR)]} {
    set build_dir $::env(NS_BUILD_DIR)
} else {
    set build_dir [file join $work_root sparse_matrix_build_[clock seconds]]
}
cd $work_root
if {[file exists $build_dir]} {error "Build directory already exists"}
file mkdir $build_dir
puts "FULL_PORT_BUILD_DIRECTORY=$build_dir"
# Run in the ASCII board staging directory prepared by tools/build_zcu104.py.
if {![info exists NS_PREPARE_ONLY]} {set NS_PREPARE_ONLY 0}
set build_impl [expr {!$NS_PREPARE_ONLY}]
create_project spmm_zcu104 [file join $build_dir project] -part xczu7ev-ffvc1156-2-e -force
set_property board_part xilinx.com:zcu104:part0:1.1 [current_project]
set_property target_language Verilog [current_project]
set_property include_dirs [list [file join $pkg project src inc]] [current_fileset]
add_files [glob [file join $pkg project src *.sv]]
add_files [glob [file join $pkg project board *.sv]]
add_files [glob [file join $pkg project board *.v]]


update_compile_order -fileset sources_1
set_property top spmm_zcu104 [current_fileset]
# Package the RTL so Vivado 2018.3 does not rely on module-reference discovery.
ipx::package_project -root_dir [file join $build_dir ip_repo spmm] -vendor user.org -library user -taxonomy /UserIP -import_files -set_current true
set ip [ipx::current_core]
set_property name spmm_zcu104 $ip
set_property version 1.0 $ip
# package_project infers AXI, clock and reset from ports and metadata.
ipx::associate_bus_interfaces -busif s_axi -clock clk $ip
ipx::save_core $ip
set_property ip_repo_paths [list [file join $build_dir ip_repo]] [current_project]
update_ip_catalog
create_bd_design design_1
set ps_def [lindex [lsort -dictionary [get_ipdefs -all xilinx.com:ip:zynq_ultra_ps_e:*]] end]
create_bd_cell -type ip -vlnv $ps_def ps
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} [get_bd_cells ps]
set_property -dict [list CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__USE__M_AXI_GP1 {0} CONFIG.PSU__USE__M_AXI_GP2 {0} CONFIG.PSU__FPGA_PL0_ENABLE {1} CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {50}] [get_bd_cells ps]
create_bd_cell -type ip -vlnv user.org:user:spmm_zcu104:1.0 accel
create_bd_cell -type ip -vlnv [lindex [lsort -dictionary [get_ipdefs -all xilinx.com:ip:axi_interconnect:*]] end] axi
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi]
create_bd_cell -type ip -vlnv [lindex [lsort -dictionary [get_ipdefs -all xilinx.com:ip:proc_sys_reset:*]] end] reset
set_property CONFIG.C_EXT_RESET_HIGH {0} [get_bd_cells reset]
connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_pins ps/maxihpm0_fpd_aclk] [get_bd_pins accel/clk] [get_bd_pins reset/slowest_sync_clk] [get_bd_pins axi/ACLK] [get_bd_pins axi/S00_ACLK] [get_bd_pins axi/M00_ACLK]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins reset/ext_reset_in]
connect_bd_net [get_bd_pins reset/peripheral_aresetn] [get_bd_pins accel/rst_n] [get_bd_pins axi/S00_ARESETN] [get_bd_pins axi/M00_ARESETN]
connect_bd_net [get_bd_pins reset/interconnect_aresetn] [get_bd_pins axi/ARESETN]
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins axi/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi/M00_AXI] [get_bd_intf_pins accel/s_axi]
assign_bd_address
set segment [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps/Data] -filter {NAME =~ *accel*}]
if {[llength $segment]!=1} {error "Expected exactly one accelerator address segment: $segment"}
set_property offset 0xA0000000 $segment
set_property range 64K $segment
validate_bd_design
save_bd_design
write_bd_tcl -force [file join $build_dir recreate_bd.tcl]
set_property synth_checkpoint_mode None [get_files design_1.bd]
generate_target all [get_files design_1.bd]
make_wrapper -files [get_files design_1.bd] -top
add_files [file join $build_dir project spmm_zcu104.srcs sources_1 bd design_1 hdl design_1_wrapper.v]
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "ZCU104_BD_PASS"
if {$build_impl} {
    synth_design -top design_1_wrapper -part xczu7ev-ffvc1156-2-e
    opt_design
    place_design
    phys_opt_design
    route_design
    report_timing_summary -file [file join $build_dir timing_routed.rpt]
    report_utilization -file [file join $build_dir utilization_routed.rpt]
    report_drc -file [file join $build_dir drc_routed.rpt]

if {![file isdirectory $build_dir]} {error "Expected build directory is missing"}
if {[current_design] eq ""} {error "Keep the routed design open in the original Vivado session"}

# These boolean checks are supported by Vivado 2018.3.
if {![report_route_status -boolean_check ROUTED_FULLY]} {error "Design is not fully routed; stop"}
if {[report_route_status -boolean_check ERRORS_IN_ROUTES]} {error "Routing errors detected; stop"}
# Preserve the expensive routed result before any additional report/export work.
write_checkpoint -force [file join $build_dir routed.dcp]

set clocks [get_clocks -quiet clk_pl_0]
if {[llength $clocks]!=1} {error "Expected exactly one clk_pl_0 clock"}
set period_ns [get_property PERIOD $clocks]
if {abs($period_ns-20.0)>0.001} {error "Expected the validated 50 MHz / 20 ns clock"}

set timing_text [report_timing_summary -return_string]
set f [open [file join $build_dir timing_routed.rpt] w]
puts $f $timing_text
close $f
if {![string match {*All user specified timing constraints are met.*} $timing_text]} {
    error "Timing summary did not confirm all timing constraints are met"
}

# all_registers has no -no_clock option in Vivado 2018.3. Use check_timing.
set timing_checks [check_timing -override_defaults {no_clock unconstrained_internal_endpoints} -return_string]
set f [open [file join $build_dir timing_checks.rpt] w]
puts $f $timing_checks
close $f
if {![regexp {There are ([0-9]+) register/latch pins with no clock} $timing_checks -> no_clock_pins]} {
    error "Cannot parse no_clock check; stop rather than bypass validation"
}
if {![regexp {There are ([0-9]+) pins that are not constrained for maximum delay[.]} $timing_checks -> unconstrained_pins]} {
    error "Cannot parse unconstrained endpoint check; stop rather than bypass validation"
}
if {$no_clock_pins!=0 || $unconstrained_pins!=0} {error "Unclocked or unconstrained endpoints found"}
set setup_paths [get_timing_paths -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup_paths]!=1 || [llength $hold_paths]!=1} {error "Missing timing paths"}
set setup_slack [get_property SLACK $setup_paths]
set hold_slack [get_property SLACK $hold_paths]
if {$setup_slack<0 || $hold_slack<0} {error "Setup or hold check failed"}
report_route_status -file [file join $build_dir route_status.rpt]

set hwh_source [file join $build_dir project spmm_zcu104.srcs sources_1 bd design_1 hw_handoff design_1.hwh]
if {![file exists $hwh_source]} {error "Matching HWH is missing; stop"}
file mkdir [file join $build_dir export]
write_bitstream -force [file join $build_dir export sparse_matrix_full.bit]
file copy -force $hwh_source [file join $build_dir export sparse_matrix_full.hwh]
write_hwdef -force -file [file join $build_dir export sparse_matrix_full.hdf]
set proof [open [file join $build_dir export build_proof.json] w]
puts $proof [format {{"image_id":"0x4e533201","target_pl_mhz":50.0,"period_ns":%s,"setup_path_slack_ns":%s,"hold_path_slack_ns":%s,"no_clock_pins":%s,"unconstrained_internal_endpoints":%s,"fully_routed":true,"routing_errors":false,"board_tested":false}} $period_ns $setup_slack $hold_slack $no_clock_pins $unconstrained_pins]
close $proof
puts "SPARSE_MATRIX_FULL_IMPLEMENT_PASS export=[file join $build_dir export]"

}
