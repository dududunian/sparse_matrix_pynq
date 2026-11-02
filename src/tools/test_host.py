"""Host tiling/packing tests; model backend is explicitly not a board test."""
from pathlib import Path
import importlib.util,json,unittest
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
ns=load('ns',ROOT/'host/sparse_matrix.py')
decoder=load('decoder',ROOT/'tools/import_original_cases.py')
ref=load('original',ROOT/'tools/original_generator.py')


def lines(words,count):
    return [''.join(f'{int(x):08X}' for x in words[i*66:(i+1)*66][::-1]) for i in range(count)]


def model_backend(job,timeout=60):
    registers=dict(job['registers']);words=job['words'];mode=job['mode'];k=registers[0x28]
    assert len(words)==68672
    order=[int(x) for x in words[67584:67648]]
    a=decoder.decode_csv(lines(words,registers[0x30]),64,k if mode=='spmm' else 64,order if mode=='spmm' else None)
    if mode=='spmm':
        b=np.zeros((k,64),dtype=np.uint16);ptr=words[67648:67648+k+1]
        for row in range(k):
            for chunk in range(int(ptr[row]),int(ptr[row+1])):
                for value in words[33792+chunk*66+2:33792+chunk*66+66]:
                    value=int(value)
                    if value:b[row,value>>16]=value&0xffff
    else:b=decoder.decode_csv(lines(words[33792:],registers[0x40]),64,64)
    def rows(x):return [[(int(j),f'{int(row[j]):04X}') for j in np.flatnonzero(row&0x7fff)] for row in x]
    if mode=='spmm':out=ref.build_golden_spmm(rows(a),rows(b),64,64)
    else:out=ref.build_golden_addsub(rows(a),rows(b),64,64,mode)
    out=np.array([[int(x,16) for x in r] for r in out],dtype=np.uint16)
    return out,dict(pl_time_ms=0,pl_cycles=0,pl_clock_hz=50000000)


def model_accelerator():
    acc=object.__new__(ns.Accelerator);acc.run_tile=model_backend
    return acc


class HostTests(unittest.TestCase):
    def test_original_28_through_independent_decode_model(self):
        manifest=json.loads((ROOT.parent/'data/original_cases/manifest.json').read_text())
        for entry in manifest['cases']:
            with self.subTest(case=entry['name']):
                with np.load(ROOT.parent/'data/original_cases'/entry['file'],allow_pickle=False) as d:
                    a,b,want=d['A_bits'],d['B_bits'],d['golden_bits']
                got,report=model_accelerator().calculate_bits(a,b,entry['mode'],entry['block_vecs'],expected=want)
                self.assertTrue(report['passed'])
                self.assertTrue(np.array_equal(got,want))

    def test_512_rows_columns_in_all_modes(self):
        a=np.eye(512,dtype=np.uint16)*0x3c00;b=a.copy()
        for mode in ns.MODES:
            with self.subTest(mode=mode):
                want=a if mode=='spmm' else (a.copy()*0 if mode=='sub' else a.copy())
                if mode=='add':want[want!=0]=0x4000
                got,report=model_accelerator().calculate_bits(a,b,mode,expected=want)
                self.assertEqual(report['tiles'],64)
                self.assertTrue(report['passed'])
                self.assertTrue(np.array_equal(got,want))

    def test_k_is_not_split_or_reassociated(self):
        a=ns.quantize(np.ones((1,512)));a[0,0]=ns.half_bits(2048)
        b=ns.quantize(np.ones((512,1)))
        want=np.array([[ns.half_bits(2048)]],dtype=np.uint16)
        got,report=model_accelerator().calculate_bits(a,b,expected=want)
        self.assertEqual(report['tiles'],1)
        self.assertTrue(np.array_equal(got,want))

    def test_invalid_values_shapes_modes_and_block_sizes(self):
        for value in [[[np.inf]],[[np.nan]],[[65505]],[[1+1j]],[["1"]],np.zeros((513,1)),np.zeros((1,0))]:
            with self.subTest(value=str(value)[:30]):
                with self.assertRaises(ValueError):ns.quantize(value)
        a=ns.quantize([[1,2]])
        b=ns.quantize([[1]])
        with self.assertRaises(ValueError):ns.prepare_tile(a,b)
        for mode in ['mul','',3]:
            with self.assertRaises(ValueError):ns.prepare_tile(b,b,mode)
        for block in [0,33,1.5]:
            with self.assertRaises(ValueError):ns.prepare_tile(b,b,block_vecs=block)

    def test_padding_and_empty_operands(self):
        a=ns.quantize([[0]]);b=ns.quantize([[1]])
        for mode in ns.MODES:
            job=ns.prepare_tile(a,b,mode)
            output,_=model_backend(job)
            want=0 if mode=='spmm' else ns.half_bits(1 if mode=='add' else -1)
            self.assertEqual(int(output[0,0]),want)
            self.assertEqual(np.count_nonzero(output),int(want!=0))

if __name__=='__main__':unittest.main()
