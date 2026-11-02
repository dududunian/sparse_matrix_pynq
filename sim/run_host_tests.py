from pathlib import Path
import subprocess,sys
root=Path(__file__).resolve().parents[1]
raise SystemExit(subprocess.call([sys.executable,'-B',str(root/'src/tools/test_host.py')],cwd=root))
