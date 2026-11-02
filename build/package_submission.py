from pathlib import Path
import hashlib,json,subprocess,shutil,os
root=Path(__file__).resolve().parents[1]
files=[p for p in root.rglob('*') if p.is_file() and '__pycache__' not in p.parts and p.suffix!='.pyc' and 'run_work' not in p.relative_to(root).parts and p!=root/'manifest.json']
manifest=dict(project='sparse_matrix_pynq',title='稀疏矩阵计算平台',code_package_ready=True,all_portal_materials_complete=False,ai_records_review_required=True,full_rebuild_performed=False,board_validation='evidence/submission_board/summary.json',files={p.relative_to(root).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)})
(root/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
rar=os.environ.get('RAR_EXE') or shutil.which('rar') or 'D:/winrar/Rar.exe'
archive=root.parent/'sparse_matrix_pynq_code.rar'
if archive.exists():raise SystemExit('Archive already exists; rename it as a backup before repackaging.')
subprocess.run([rar,'a','-r','-m5','-idq','-x*__pycache__*','-x*.pyc','-x*run_work*',str(archive),root.name],cwd=root.parent,check=True)
subprocess.run([rar,'t','-idq',str(archive)],check=True)
assert archive.stat().st_size<200000000
print(str(archive),archive.stat().st_size,hashlib.sha256(archive.read_bytes()).hexdigest())
