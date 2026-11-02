"""Decode supplied raw ROM files, preserving original FP16 Golden bit patterns."""
from pathlib import Path
import hashlib,importlib.util,json
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('sparse_matrix',ROOT/'host/sparse_matrix.py')
ns=importlib.util.module_from_spec(spec);spec.loader.exec_module(ns)


def decode_csv(lines,m,n,order=None):
    result=np.zeros((m,n),dtype=np.uint16);cursor=0
    for base in range(0,m,64):
        active=(1<<min(64,m-base))-1
        while active:
            if cursor>=len(lines):raise ValueError('CSV ended before row group completed')
            value=int(lines[cursor],16);cursor+=1;eor=value&((1<<64)-1)
            for lane in range(min(64,m-base)):
                if not (active>>lane)&1:continue
                word=(value>>(32*(2+lane)))&0xffffffff
                if word:
                    col=word>>16;bits=word&0xffff
                    if col>=n:raise ValueError('CSV index exceeds logical matrix')
                    row=order[base+lane] if order is not None else base+lane
                    result[row,col]=bits
            active&=~eor
    if cursor!=len(lines):raise ValueError('Trailing unused CSV vectors')
    return result


def import_cases(original_project):
    out=ROOT.parent/'data/original_cases';out.mkdir(exist_ok=True)
    records=[]
    for case in sorted((original_project/'testcase').iterdir()):
        if not (case/'case.json').exists():continue
        meta=json.loads((case/'case.json').read_text(encoding='utf-8'))
        m,n,k=[meta[x] for x in ['M','N','K']];mode=meta['mode']
        lines=lambda name:(case/name).read_text().split()
        order=[int(x,16) for x in lines('a_row_order.hex')]
        a=decode_csv(lines('a_compact_vec.hex'),m,k if mode=='spmm' else n,order if mode=='spmm' else None)
        bv=lines('b_val_pack.hex')
        if mode=='spmm':
            b=np.zeros((k,n),dtype=np.uint16)
            ptr=[int(x,16) for x in lines('b_row_ptr.hex')]
            assert len(ptr)==k+1
            for row in range(k):
                for chunk in range(ptr[row],ptr[row+1]):
                    value=int(bv[chunk],16)
                    for lane in range(64):
                        word=(value>>(32*(lane+2)))&0xffffffff
                        if word:
                            col=word>>16
                            if col>=n:raise ValueError('B column exceeds logical size')
                            b[row,col]=word&0xffff
        else:b=decode_csv(bv,m,n)
        golden=np.array([int(x,16) for x in lines('golden_c.hex')],dtype=np.uint16).reshape(m,n)
        reference=ns.reference_bits(a,b,mode)
        assert np.array_equal(reference,golden),case.name+' decoded reference mismatch'
        file=out/(case.name+'.npz')
        np.savez_compressed(file,A_bits=a,B_bits=b,golden_bits=golden)
        records.append(dict(name=case.name,file=file.name,sha256=hashlib.sha256(file.read_bytes()).hexdigest(),
                            mode=mode,shape=[m,n,k],block_vecs=meta['W'],
                            original_files={name:hashlib.sha256((case/name).read_bytes()).hexdigest()
                              for name in ['a_compact_vec.hex','a_row_order.hex','b_row_ptr.hex','b_val_pack.hex','golden_c.hex']}))
        print('ORIGINAL_CASE_IMPORTED',case.name,flush=True)
    assert len(records)==28
    (out/'manifest.json').write_text(json.dumps(dict(cases=records,source='User-provided original project archive',
        numerical_reference='Original golden_c.hex, bit-exact after raw input decoding'),indent=2))
    return records


if __name__=='__main__':
    import argparse
    ap=argparse.ArgumentParser();ap.add_argument('original_project',type=Path);args=ap.parse_args()
    import_cases(args.original_project)
