"""Synthesize only the updated accelerator to check ZCU104 resource headroom.

This is not a placed/routed PS+PL build and cannot produce a deployable bit.
"""
from pathlib import Path
import hashlib,json,os,subprocess,tempfile,time

ROOT=Path(__file__).resolve().parents[1]
out=ROOT.parent/'evidence/reproduced/resource_check';out.mkdir(parents=True,exist_ok=True)
proof=json.loads((ROOT.parent/'evidence/full_rtl/summary.json').read_text())
assert proof['passed']
snapshot=json.loads((ROOT.parent/'evidence/full_rtl/source_manifest.json').read_text())
for name,digest in snapshot.items():
    assert hashlib.sha256((ROOT/'project'/name.replace('\\','/').lower()).read_bytes()).hexdigest()==digest,name
base=Path(os.environ.get('NS_WORK_DIR','D:/Codex_Vivado_Work'));base.mkdir(parents=True,exist_ok=True)
stage=Path(tempfile.mkdtemp(prefix='ns_ooc_',dir=base))
source=ROOT/'project'
script=f'''set_param general.maxThreads 2
create_project -in_memory -part xczu7ev-ffvc1156-2-e
set_property include_dirs [list {{{source.as_posix()}/src/inc}}] [current_fileset]
add_files [glob {{{source.as_posix()}/src/*.sv}}]
add_files [glob {{{source.as_posix()}/board/*.sv}}]
add_files [glob {{{source.as_posix()}/board/*.v}}]
set_property top spmm_zcu104 [current_fileset]
update_compile_order -fileset sources_1
synth_design -top spmm_zcu104 -part xczu7ev-ffvc1156-2-e -mode out_of_context
report_utilization -file {{{out.as_posix()}/utilization_synth.rpt}}
write_checkpoint -force {{{stage.as_posix()}/core_synth.dcp}}
puts "FULL_PORT_RESOURCE_SYNTH_PASS"
exit
'''
tcl=out/'resource_check.tcl';tcl.write_text(script)
print('Full-port resource synthesis started',flush=True)
with (out/'console.log').open('w',encoding='utf-8') as log:
    process_env=os.environ.copy();process_env['TEMP']=process_env['TMP']=str(base)
    run=subprocess.run([str(Path(os.environ.get('VIVADO_BIN','D:/Vivado/Vivado/2018.3/bin'))/('vivado.bat' if os.name=='nt' else 'vivado')),'-mode','batch','-nojournal','-nolog','-source',str(tcl)],
                        cwd=stage,env=process_env,stdout=log,stderr=subprocess.STDOUT,text=True,timeout=3600)
text=(out/'console.log').read_text(encoding='utf-8',errors='replace')
passed=run.returncode==0 and 'FULL_PORT_RESOURCE_SYNTH_PASS' in text
(out/'summary.json').write_text(json.dumps(dict(passed=passed,stage=str(stage),board_tested=False,
    scope='Accelerator out-of-context synthesis only; no PS+PL routing/timing proof'),indent=2))
print('RESOURCE_SYNTH',passed,flush=True)
if not passed:print(text[-5000:]);raise SystemExit(1)
