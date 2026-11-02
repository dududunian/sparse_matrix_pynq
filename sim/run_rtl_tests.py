from pathlib import Path
import os,subprocess,sys
root=Path(__file__).resolve().parents[1]
env=os.environ.copy();work=Path(env.get('NS_WORK_DIR',str(root/'run_work'))).resolve();work.mkdir(parents=True,exist_ok=True)
if os.name=='nt' and work.drive.upper()=='C:':raise RuntimeError('Choose a D: work location')
env.update(NS_WORK_DIR=str(work),TEMP=str(work),TMP=str(work))
for flags in [[],['--numerical-only']]:
    subprocess.run([sys.executable,'-B',str(root/'src/tools/test_rtl.py'),*flags],cwd=root,env=env,check=True)
