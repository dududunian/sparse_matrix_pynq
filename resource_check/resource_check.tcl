set_param general.maxThreads 2
create_project -in_memory -part xczu7ev-ffvc1156-2-e
set_property include_dirs [list {C:/Users/20560/Documents/Codex/2026-10-24/https-pynq-readthedocs-io-en-v2-2/work/full_port/project/src/inc}] [current_fileset]
add_files [glob {C:/Users/20560/Documents/Codex/2026-10-24/https-pynq-readthedocs-io-en-v2-2/work/full_port/project/src/*.sv}]
add_files [glob {C:/Users/20560/Documents/Codex/2026-10-24/https-pynq-readthedocs-io-en-v2-2/work/full_port/project/board/*.sv}]
add_files [glob {C:/Users/20560/Documents/Codex/2026-10-24/https-pynq-readthedocs-io-en-v2-2/work/full_port/project/board/*.v}]
set_property top spmm_zcu104 [current_fileset]
update_compile_order -fileset sources_1
synth_design -top spmm_zcu104 -part xczu7ev-ffvc1156-2-e -mode out_of_context
report_utilization -file {C:/Users/20560/Documents/Codex/2026-10-24/https-pynq-readthedocs-io-en-v2-2/work/full_port/evidence/resource_check/utilization_synth.rpt}
write_checkpoint -force {D:/Codex_Vivado_Work/ns_ooc_nrahhzqn/core_synth.dcp}
puts "FULL_PORT_RESOURCE_SYNTH_PASS"
exit
