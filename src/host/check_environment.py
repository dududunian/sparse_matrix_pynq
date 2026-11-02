"""Read-only board environment capture. Does not program the PL."""
import json,pathlib,platform
report=dict(machine=platform.machine(),system=platform.system(),python=platform.python_version())
model=pathlib.Path('/proc/device-tree/model')
report['board_model']=model.read_bytes().rstrip(b'\0').decode(errors='replace') if model.exists() else 'unavailable'
try:
    import pynq
    from pynq import Overlay,MMIO
    from pynq.ps import Clocks
    report['pynq_version']=getattr(pynq,'__version__','unknown')
    report['overlay_mmio_importable']=True
    report['clocks_api_importable']=True
except Exception as error:
    report['pynq_version']=None;report['overlay_mmio_importable']=False;report['clocks_api_importable']=False;report['error_type']=type(error).__name__;report['error']=str(error)
report['python_environment_ready']=report['machine']=='aarch64' and report['overlay_mmio_importable']
pathlib.Path('board_environment.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
print('PYENV_READY (hardware compatibility still requires testing)' if report['python_environment_ready'] else 'PYENV_NOT_READY')
