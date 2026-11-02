"""ZCU104 system port of the original SpMM/ADD/SUB project.

Logical matrices are at most 512x512. FPGA tiles are 64x64 with K<=512.
Only M/N are tiled: no host partial-sum arithmetic and no K reassociation.
Numerical contract matches the project's binary16, separate MUL/ADD,
round-to-nearest-even and finite-overflow saturation reference.
"""
from pathlib import Path
import hashlib,json,math,re,struct,time,zipfile
import numpy as np

IMAGE_ID=0x4e533201
IMAGE_WORDS=68672
MODES={'spmm':0,'add':1,'sub':2}


def half_bits(value):
    value=float(value)
    if math.isnan(value):return 0x7e00
    if math.isfinite(value) and abs(value)>65504:value=math.copysign(65504,value)
    return int.from_bytes(struct.pack('>e',value),'big')


def half_value(bits):
    return struct.unpack('>e',int(bits).to_bytes(2,'big'))[0]


def quantize(matrix):
    x=np.asarray(matrix)
    if x.ndim!=2 or x.dtype.kind not in 'biuf':raise ValueError('Expected a two-dimensional real matrix')
    if not all(1<=n<=512 for n in x.shape):raise ValueError('Each logical dimension must be in 1..512')
    if not np.isfinite(x).all() or (np.abs(x.astype(float))>65504).any():
        raise ValueError('Inputs must be finite binary16-range values')
    result=np.array([[half_bits(v) for v in row] for row in x],dtype=np.uint16)
    result[(result&0x7fff)==0]=0
    return result


def validate_shapes(a,b,mode):
    if mode not in MODES:raise ValueError('mode must be spmm, add or sub')
    if a.ndim!=2 or b.ndim!=2 or a.dtype!=np.uint16 or b.dtype!=np.uint16:
        raise ValueError('Expected binary16 bit arrays')
    if not all(1<=n<=512 for n in a.shape+b.shape):raise ValueError('Dimensions must be in 1..512')
    if mode=='spmm':
        if a.shape[1]!=b.shape[0]:raise ValueError('SPMM requires A[M,K] and B[K,N]')
        return a.shape[0],b.shape[1],a.shape[1]
    if a.shape!=b.shape:raise ValueError('ADD/SUB require equal matrix shapes')
    return a.shape[0],a.shape[1],a.shape[1]


def reference_bits(a,b,mode='spmm'):
    m,n,k=validate_shapes(a,b,mode)
    c=np.zeros((m,n),dtype=np.uint16)
    if mode=='spmm':
        brows=[[(int(j),int(row[j])) for j in np.flatnonzero(row&0x7fff)] for row in b]
        for i,row in enumerate(a):
            for kk in np.flatnonzero(row&0x7fff):
                av=half_value(row[kk])
                for j,bv in brows[int(kk)]:
                    product=half_bits(av*half_value(bv))
                    c[i,j]=half_bits(half_value(c[i,j])+half_value(product))
    else:
        for i in range(m):
            for j in np.flatnonzero((a[i]&0x7fff)|(b[i]&0x7fff)):
                av,bv=int(a[i,j]),int(b[i,j])
                if not av&0x7fff:c[i,j]=bv^(0x8000 if mode=='sub' else 0)
                elif not bv&0x7fff:c[i,j]=av
                else:c[i,j]=half_bits(half_value(av)+(1 if mode=='add' else -1)*half_value(bv))
    return c


def compact_vectors(bits):
    """Identity row-order, one 64-row group, word0 at the low end."""
    rows=[[int(j) for j in np.flatnonzero(row&0x7fff)] for row in bits]
    count=max(1,max(map(len,rows)))
    data=np.zeros((count,66),dtype=np.uint32)
    for t in range(count):
        eor=0
        for i,cols in enumerate(rows):
            if t<len(cols):
                j=cols[t];data[t,2+i]=(j<<16)|int(bits[i,j])
            if t==max(0,len(cols)-1):eor|=1<<i
        data[t,0]=eor&0xffffffff;data[t,1]=eor>>32
    return data


def prepare_tile(a,b,mode='spmm',block_vecs=8):
    m,n,k=validate_shapes(a,b,mode)
    if m>64 or n>64:raise ValueError('Physical tile exceeds 64x64')
    if not isinstance(block_vecs,(int,np.integer)) or not 1<=block_vecs<=32:
        raise ValueError('block_vecs must be an integer in 1..32')
    pa=np.zeros((64,k if mode=='spmm' else 64),dtype=np.uint16)
    pa[:m,:a.shape[1]]=a
    av=compact_vectors(pa)
    image=np.zeros(IMAGE_WORDS,dtype=np.uint32)
    image[:av.size]=av.flat
    if mode=='spmm':
        ptr=[0];bv=[]
        for row in b:
            cols=[int(j) for j in np.flatnonzero(row&0x7fff)]
            if cols:
                words=[0]*66
                for lane,j in enumerate(cols):words[lane+2]=(j<<16)|int(row[j])
                bv.extend(words)
            ptr.append(len(bv)//66)
        image[33792:33792+len(bv)]=bv
        chunks=len(bv)//66
        ptr_count=k+1
        image[67648:67648+len(ptr)]=ptr
    else:
        pb=np.zeros((64,64),dtype=np.uint16);pb[:m,:n]=b
        bv=compact_vectors(pb)
        image[33792:33792+bv.size]=bv.flat
        chunks=len(bv);ptr_count=1
    image[67584:67648]=np.arange(64,dtype=np.uint32)
    registers=[(0x20,64),(0x24,64),(0x28,k if mode=='spmm' else 64),
               (0x2c,int(block_vecs)),(0x30,len(av)),(0x34,MODES[mode]),
               (0x38,0),(0x3c,0),(0x40,chunks),(0x44,ptr_count)]
    return dict(words=image,registers=registers,shape=(m,n,k),mode=mode)


def tile_jobs(a,b,mode='spmm',block_vecs=8):
    m,n,k=validate_shapes(a,b,mode)
    for r in range(0,m,64):
        for c in range(0,n,64):
            at=a[r:r+64,:] if mode=='spmm' else a[r:r+64,c:c+64]
            bt=b[:,c:c+64] if mode=='spmm' else b[r:r+64,c:c+64]
            yield r,c,prepare_tile(at,bt,mode,block_vecs)


class Accelerator:
    def __init__(self,folder='.'):
        folder=Path(folder).resolve()
        config=json.loads((folder/'board_config.json').read_text())
        if config.get('timing_validated') is not True or config.get('image_id')!=hex(IMAGE_ID):
            raise ValueError('A timing-validated full-port hardware package is required')
        for ext in ['bit','hwh']:
            path=folder/f'sparse_matrix_full.{ext}'
            if hashlib.sha256(path.read_bytes()).hexdigest()!=config[ext+'_sha256']:
                raise ValueError('Mismatched hardware file: '+str(path))
        from pynq import Overlay,MMIO
        from pynq.ps import Clocks
        self.overlay=Overlay(str(folder/'sparse_matrix_full.bit'))
        target=float(config['target_pl_mhz']);Clocks.fclk0_mhz=target
        self.clock_hz=round(float(Clocks.fclk0_mhz)*1000000)
        if abs(self.clock_hz-target*1000000)>100000:raise RuntimeError('PL clock readback mismatch')
        self.io=MMIO(0xA0000000,0x10000)
        expected={0:0x53504d31,0x14:IMAGE_ID,0x54:IMAGE_WORDS,0x58:64,0x5c:512,0x60:7}
        if any(self.io.read(addr)!=value for addr,value in expected.items()):
            raise RuntimeError('Wrong accelerator revision or capabilities; stop')

    def _idle(self,timeout):
        until=time.monotonic()+timeout
        while self.io.read(8)&1:
            if time.monotonic()>until:raise TimeoutError('Core did not become idle')
            time.sleep(.001)

    def run_tile(self,job,timeout=60):
        io=self.io;started=time.perf_counter();self._idle(timeout)
        io.write(0x48,0)
        for word in job['words']:io.write(0x4c,int(word))
        if io.read(0x48)!=IMAGE_WORDS or io.read(0x50)!=1:raise RuntimeError('Input upload incomplete')
        for addr,value in job['registers']:io.write(addr,int(value))
        uploaded=time.perf_counter();count=(io.read(0x10)+1)&0xffffffff
        io.write(4,1);until=time.monotonic()+timeout
        while True:
            status=io.read(8)
            if status&2 and io.read(0x10)==count:break
            if time.monotonic()>until:raise TimeoutError(f'Task timeout status=0x{status:08x}')
            time.sleep(.001)
        if status&4 or status&0xff00:raise RuntimeError(f'Hardware error status=0x{status:08x}')
        self._idle(timeout);completed=time.perf_counter();cycles=io.read(0xc)
        result=np.array([io.read(0x4000+i*4)&0xffff for i in range(4096)],dtype=np.uint16).reshape(64,64)
        finished=time.perf_counter()
        return result,dict(completed_counter=count,pl_cycles=cycles,pl_clock_hz=self.clock_hz,
                           pl_time_ms=cycles*1000/self.clock_hz,upload_seconds=uploaded-started,
                           wait_seconds=completed-uploaded,readback_seconds=finished-completed)

    def calculate_bits(self,a,b,mode='spmm',block_vecs=8,expected=None,timeout=60):
        m,n,k=validate_shapes(a,b,mode);started=time.perf_counter()
        if expected is None:expected=reference_bits(a,b,mode)
        if expected.shape!=(m,n) or expected.dtype!=np.uint16:raise ValueError('Reference shape/dtype mismatch')
        output=np.zeros((m,n),dtype=np.uint16);reports=[]
        for r,c,job in tile_jobs(a,b,mode,block_vecs):
            tile,report=self.run_tile(job,timeout)
            rows,cols=job['shape'][:2]
            output[r:r+rows,c:c+cols]=tile[:rows,:cols]
            want=np.zeros((64,64),dtype=np.uint16);want[:rows,:cols]=expected[r:r+rows,c:c+cols]
            report.update(row=r,col=c,mismatches=int(np.count_nonzero(tile!=want)))
            reports.append(report)
            if report['mismatches']:
                break
        passed=len(reports)==math.ceil(m/64)*math.ceil(n/64) and all(x['mismatches']==0 for x in reports)
        report=dict(passed=passed,mode=mode,shape=[m,n,k],tiles=len(reports),
                    mismatches=sum(x['mismatches'] for x in reports),
                    pl_time_ms=sum(x['pl_time_ms'] for x in reports),
                    elapsed_seconds=time.perf_counter()-started,tile_results=reports)
        return output,report

    def calculate(self,a,b,mode='spmm',block_vecs=8,timeout=60):
        bits,report=self.calculate_bits(quantize(a),quantize(b),mode,block_vecs,timeout=timeout)
        return bits.view(np.float16).copy(),report


def run_original_suite(folder='.',cases='original_cases',output='full_results'):
    """Run the original 28 Golden cases on actual hardware, one Overlay load."""
    folder=Path(folder);cases=Path(cases);out=Path(output);out.mkdir(exist_ok=True)
    manifest=json.loads((cases/'manifest.json').read_text())
    entries=manifest['cases'];reports=[]
    def save(error=None):
        state=dict(passed=error is None and len(reports)==28 and all(x['passed'] for x in reports),
                   image_id=hex(IMAGE_ID),expected_cases=28,completed_cases=len(reports),results=reports)
        if error is not None:state.update(error_type=type(error).__name__,error=str(error))
        (out/'report.json').write_text(json.dumps(state,indent=2))
    save()
    try:
        if len(entries)!=28:raise ValueError('Expected exactly the original 28 cases')
        acc=Accelerator(folder)
        print(f'PL clock register readback: {acc.clock_hz/1000000:.3f} MHz',flush=True)
        for entry in entries:
            path=cases/entry['file']
            if hashlib.sha256(path.read_bytes()).hexdigest()!=entry['sha256']:raise ValueError('Case checksum mismatch')
            with np.load(path,allow_pickle=False) as data:
                a,b,golden=data['A_bits'],data['B_bits'],data['golden_bits']
            bits,report=acc.calculate_bits(a,b,entry['mode'],entry['block_vecs'],expected=golden)
            report.update(case=entry['name'],logical_values=int(golden.size))
            reports.append(report)
            np.savez(out/(entry['name'].lower()+'.npz'),C_bits=bits,golden_bits=golden)
            save()
            print(entry['name'],json.dumps({key:report[key] for key in ['passed','mode','shape','tiles','mismatches','pl_time_ms']}),flush=True)
            if not report['passed']:raise RuntimeError('Original case mismatch; preserve full_results')
    except Exception as error:
        save(error);raise
    print('ORIGINAL_SUITE_PASS: all 28 original cases match, SpMM/ADD/SUB',flush=True)
    return reports


def extract_original_cases(archive='original_cases.zip',output='original_cases'):
    """Extract only the named, checksummed numerical fixtures from this package."""
    out=Path(output);out.mkdir(exist_ok=True)
    with zipfile.ZipFile(archive) as z:
        raw=z.read('manifest.json');manifest=json.loads(raw)
        entries=manifest['cases']
        if len(entries)!=28 or len({x['name'] for x in entries})!=28:raise ValueError('Invalid original case list')
        for entry in entries:
            name=entry['file']
            if re.fullmatch(r'[A-Za-z0-9_]+\.npz',name) is None:raise ValueError('Invalid case filename')
            data=z.read(name)
            if hashlib.sha256(data).hexdigest()!=entry['sha256']:raise ValueError('Invalid case checksum')
            (out/name).write_bytes(data)
        (out/'manifest.json').write_bytes(raw)
    print('ORIGINAL_CASES_READY: 28 checksummed numerical fixtures')


def run_boundary_suite(folder='.',output='boundary_results'):
    """Actual-board acceptance for the advertised logical 512 limit in all modes."""
    out=Path(output);out.mkdir(exist_ok=True);results=[]
    eye=np.eye(512,dtype=np.uint16)*0x3c00
    twice=eye.copy();twice[twice!=0]=0x4000
    dense_a=np.full((1,512),0x3c00,dtype=np.uint16)
    dense_b=np.full((512,64),0x3c00,dtype=np.uint16)
    rounding_a=dense_a.copy();rounding_a[0,0]=half_bits(2048)
    cases=[('spmm_identity512',eye,eye,'spmm',eye),
           ('add_identity512',eye,eye,'add',twice),
           ('sub_cancel512',eye,eye,'sub',np.zeros_like(eye)),
           ('dense_k512',dense_a,dense_b,'spmm',np.full((1,64),half_bits(512),dtype=np.uint16)),
           ('rounding_k512',rounding_a,dense_b[:,:1],'spmm',np.array([[half_bits(2048)]],dtype=np.uint16))]
    def save(error=None):
        report=dict(passed=error is None and len(results)==len(cases) and all(x['passed'] for x in results),
                    expected_cases=len(cases),completed_cases=len(results),image_id=hex(IMAGE_ID),results=results)
        if error is not None:report.update(error_type=type(error).__name__,error=str(error))
        (out/'report.json').write_text(json.dumps(report,indent=2))
    save()
    try:
        acc=Accelerator(folder)
        for name,a,b,mode,golden in cases:
            bits,report=acc.calculate_bits(a,b,mode,expected=golden)
            report['case']=name;results.append(report)
            np.savez(out/(name+'.npz'),C_bits=bits,golden_bits=golden)
            save();print(name,json.dumps({k:report[k] for k in ['passed','tiles','mismatches','pl_time_ms']}),flush=True)
            if not report['passed']:raise RuntimeError('Boundary mismatch; preserve boundary_results')
    except Exception as error:
        save(error);raise
    print('BOUNDARY_SUITE_PASS: 512-size SpMM/ADD/SUB and K=512 numerical boundaries')
    return results
