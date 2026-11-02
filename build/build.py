"""Build an independently named PS/PL project after verifying the tested RTL."""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess,sys,uuid
ROOT=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser();ap.add_argument('--check-only',action='store_true');args=ap.parse_args()
for suite in ['full_rtl','numerical_rtl']:
    data=ROOT/'evidence'/suite
    assert json.loads((data/'summary.json').read_text())['passed'],suite
    for relative,digest in json.loads((data/'source_manifest.json').read_text()).items():
        p=ROOT/'src/project'/relative.replace(chr(92),'/').lower()
        assert hashlib.sha256(p.read_bytes()).hexdigest()==digest,str(p)
print('TESTED_RTL_CONTENT_HASHES_PASS',flush=True)
if args.check_only:raise SystemExit(0)
work=Path(os.environ.get('NS_WORK_DIR',str(ROOT/'run_work'))).resolve();work.mkdir(parents=True,exist_ok=True)
if os.name=='nt' and work.drive.upper()=='C:':raise RuntimeError('Choose a D: build location with NS_WORK_DIR')
configured=os.environ.get('VIVADO_BIN')
exe=str(Path(configured)/('vivado.bat' if os.name=='nt' else 'vivado')) if configured else shutil.which('vivado')
if not exe and os.name=='nt':exe='D:/Vivado/Vivado/2018.3/bin/vivado.bat'
if not exe or not Path(exe).is_file():raise RuntimeError('Set VIVADO_BIN to the Vivado 2018.3 bin directory')
stage=work/('sparse_matrix_build_'+uuid.uuid4().hex[:8]);env=os.environ.copy()
env.update(NS_WORK_DIR=str(work),NS_BUILD_DIR=str(stage),TEMP=str(work),TMP=str(work))
logpath=work/(stage.name+'.log')
with logpath.open('w',encoding='utf-8') as log:
    result=subprocess.run([exe,'-mode','batch','-nojournal','-nolog','-source',str(ROOT/'src/start_build.tcl')],cwd=work,env=env,stdout=log,stderr=subprocess.STDOUT,text=True)
text=logpath.read_text(errors='replace');assert result.returncode==0 and re.search(r'^SPARSE_MATRIX_FULL_IMPLEMENT_PASS export=',text,re.M),str(logpath)
proof=json.loads((stage/'export/build_proof.json').read_text())
assert proof['fully_routed'] and not proof['routing_errors']
assert proof['setup_path_slack_ns']>=0 and proof['hold_path_slack_ns']>=0
print('BUILD_PASS',stage/'export','new hardware requires new board acceptance',flush=True)
