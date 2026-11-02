# Run in the ASCII board staging directory prepared by tools/build_zcu104.py.
set build_impl [expr {[llength $argv]>0 && [lindex $argv 0] eq "implement"}]
create_project spmm_zcu104 project -part xczu7ev-ffvc1156-2-e -force
set_property board_part xilinx.com:zcu104:part0:1.1 [current_project]
set_property target_language Verilog [current_project]
set_property include_dirs [list [file normalize src/inc]] [current_fileset]
add_files [glob src/*.sv]
add_files [glob board/*.sv]
add_files [glob board/*.v]
add_files [glob *.hex]
set_property file_type {Memory Initialization Files} [get_files *.hex]
update_compile_order -fileset sources_1
set_property top spmm_zcu104 [current_fileset]
# Package the RTL so Vivado 2018.3 does not rely on module-reference discovery.
ipx::package_project -root_dir ip_repo/spmm -vendor user.org -library user -taxonomy /UserIP -import_files -set_current true
set ip [ipx::current_core]
set_property name spmm_zcu104 $ip
set_property version 1.0 $ip
# package_project infers AXI, clock and reset from ports and metadata.
ipx::associate_bus_interfaces -busif s_axi -clock clk $ip
ipx::save_core $ip
set_property ip_repo_paths [list [file normalize ip_repo]] [current_project]
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
write_bd_tcl -force recreate_bd.tcl
generate_target all [get_files design_1.bd]
make_wrapper -files [get_files design_1.bd] -top
add_files project/spmm_zcu104.srcs/sources_1/bd/design_1/hdl/design_1_wrapper.v
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "ZCU104_BD_PASS"
if {$build_impl} {
    launch_runs synth_1 -jobs 2
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
    launch_runs impl_1 -to_step write_bitstream -jobs 2
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Implementation failed"}
    open_run impl_1
    report_timing_summary -file timing_routed.rpt
    report_utilization -file utilization_routed.rpt
    report_drc -file drc_routed.rpt
    set setup_paths [get_timing_paths -delay_type max -max_paths 1]
    set hold_paths [get_timing_paths -delay_type min -max_paths 1]
    if {[llength $setup_paths]==0 || [llength $hold_paths]==0} {error "Missing routed timing paths"}
    if {[get_property SLACK $setup_paths]<0 || [get_property SLACK $hold_paths]<0} {error "Routed timing failed; do not deploy"}
    set checks [check_timing -override_defaults {no_clock} -return_string]
    if {![regexp {There are ([0-9]+) register/latch pins with no clock} $checks -> no_clock_pins]} {error "Cannot parse clock validation"}
    if {$no_clock_pins!=0} {error "Registers without clocks"}
    report_route_status -file route_status.rpt
    file mkdir export
    file copy -force project/spmm_zcu104.runs/impl_1/design_1_wrapper.bit export/spmm_zcu104.bit
    file copy -force project/spmm_zcu104.srcs/sources_1/bd/design_1/hw_handoff/design_1.hwh export/spmm_zcu104.hwh
    write_hwdef -force -file export/spmm_zcu104.hdf
    puts "ZCU104_IMPLEMENT_PASS"
}
