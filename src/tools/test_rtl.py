"""Full core/AXI regression against original Golden data and 512-boundary cases.

All task control and output reads use AXI. Three selected jobs upload every
input word through AXI; other jobs preload memory hierarchically to keep this
regression practical. Preloading is simulation-only, never a board shortcut.
"""
from pathlib import Path
import argparse,hashlib,importlib.util,json,os,shutil,subprocess,tempfile,time
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser();ap.add_argument('--numerical-only',action='store_true');args=ap.parse_args()
OUT=ROOT.parent/('evidence/reproduced/numerical_rtl' if args.numerical_only else 'evidence/reproduced/full_rtl');OUT.mkdir(parents=True,exist_ok=True)
spec=importlib.util.spec_from_file_location('ns',ROOT/'host/sparse_matrix.py')
ns=importlib.util.module_from_spec(spec);spec.loader.exec_module(ns)
work_dir=Path(os.environ.get('NS_WORK_DIR','D:/Codex_Vivado_Work'))
work_dir.mkdir(parents=True,exist_ok=True)
stage=Path(tempfile.mkdtemp(prefix='ns_full_sim_',dir=work_dir))
process_env=os.environ.copy()
process_env['TEMP']=process_env['TMP']=str(work_dir)
for folder in ['src','board']:shutil.copytree(ROOT/'project'/folder,stage/folder)
(stage/'sim').mkdir();(stage/'jobs').mkdir()
entries=json.loads((ROOT.parent/'data/original_cases/manifest.json').read_text())['cases']
jobs=[];metadata=[]
for entry in entries:
    with np.load(ROOT.parent/'data/original_cases'/entry['file'],allow_pickle=False) as d:
        a,b,golden=d['A_bits'],d['B_bits'],d['golden_bits']
    for r,c,job in ns.tile_jobs(a,b,entry['mode'],entry['block_vecs']):
        want=np.zeros((64,64),dtype=np.uint16)
        rows,cols=job['shape'][:2]
        want[:rows,:cols]=golden[r:r+rows,c:c+cols]
        jobs.append((entry['name'],r,c,job,want))
# Verify the logical 512 boundary in both M/N directions without splitting K.
a=np.eye(512,dtype=np.uint16)*0x3c00
b=a.copy()
for r,c,job in ns.tile_jobs(a,b,'spmm',8):
    jobs.append(('boundary_identity512',r,c,job,a[r:r+64,c:c+64].copy()))
# Force the maximum A vector count, B chunk count, K and pointer range in one
# fully AXI-uploaded task; all 64 outputs are exactly 512 in binary16.
a=np.full((1,512),0x3c00,dtype=np.uint16)
b=np.full((512,64),0x3c00,dtype=np.uint16)
job=ns.prepare_tile(a,b,'spmm',8)
want=np.zeros((64,64),dtype=np.uint16);want[0,:]=ns.half_bits(512)
jobs.append(('boundary_dense_k512',0,0,job,want))
if args.numerical_only:
    jobs=[]
    a=np.full((1,512),0x3c00,dtype=np.uint16);a[0,0]=ns.half_bits(2048)
    b=np.full((512,1),0x3c00,dtype=np.uint16)
    want=np.zeros((64,64),dtype=np.uint16);want[0,0]=ns.half_bits(2048)
    jobs.append(('numeric_rounding_k512',0,0,ns.prepare_tile(a,b),want))
    a=ns.quantize([[65504],[2**-14],[-65504],[2**-24]])
    b=ns.quantize([[2,2**-10]])
    want=np.zeros((64,64),dtype=np.uint16)
    expected=[[65504,63.96875],[2**-13,2**-24],[-65504,-63.96875],[2**-23,0]]
    want[:4,:2]=ns.quantize(expected)
    jobs.append(('numeric_spmm_fp16',0,0,ns.prepare_tile(a,b),want))
    a=ns.quantize([[65504,2**-24,-65504,1]])
    b=ns.quantize([[65504,2**-24,-65504,-1]])
    want=np.zeros((64,64),dtype=np.uint16);want[:1,:4]=ns.quantize([[65504,2**-23,-65504,0]])
    jobs.append(('numeric_add_fp16',0,0,ns.prepare_tile(a,b,'add'),want))
    want=np.zeros((64,64),dtype=np.uint16);want[0,3]=ns.half_bits(2)
    jobs.append(('numeric_sub_fp16',0,0,ns.prepare_tile(a,b,'sub'),want))
seen=set()
for index,(name,r,c,job,want) in enumerate(jobs):
    mode=job['mode']
    upload=(mode in ('add','sub') and mode not in seen) or name=='boundary_dense_k512' or (args.numerical_only and mode not in seen)
    seen.add(mode)
    config=[value for addr,value in job['registers']]+[int(upload),int(index==len(jobs)-1 or jobs[index+1][0]!=name)]
    metadata.append(dict(job=index,case=name,row=r,col=c,mode=mode,axi_upload=upload,config=config))
    (stage/f'jobs/{index}_input.hex').write_text(''.join(f'{int(x):08x}\n' for x in job['words']))
    (stage/f'jobs/{index}_golden.hex').write_text(''.join(f'{int(x):04x}\n' for x in want.flat))
(stage/'jobs_config.hex').write_text(''.join(f'{int(x):08x}\n' for d in metadata for x in d['config']))
(OUT/'jobs.json').write_text(json.dumps(metadata,indent=2))
print('FULL_RTL_JOBS',len(jobs),'original cases',len(entries),'boundary cases',2,flush=True)

# Reuse the proven bus master tasks; the DUT and case sequence are new.
header=(ROOT/'tools/axi_tasks.sv').read_text()
header=header.replace('module tb_spmm_axi;','module tb_sparse_matrix_full;').replace('always #5 clk','always #10 clk')
header=header.replace('polls>10000','polls>500000')
body='''
    reg [31:0] input_words[0:68671];
    reg [31:0] cfg[0:CONFIG_MAX];
    reg fast_load=0;
    integer job,j,base,rr;
    genvar bank;
    generate for(bank=0;bank<66;bank=bank+1) begin: PRELOAD
        integer row;
        always @(posedge fast_load) begin
            for(row=0;row<512;row=row+1) begin
                dut.u_core.u_a_input.BANK[bank].mem[row]=input_words[row*66+bank];
                dut.u_core.u_b_input.BANK[bank].mem[row]=input_words[33792+row*66+bank];
            end
        end
    end endgenerate
    initial begin
        $readmemh("jobs_config.hex",cfg);
        repeat(3) @(negedge clk);rst_n=1;repeat(5) @(negedge clk);
        read_reg(16'h0014,0,value);if(value!==32'h4e533201) $fatal(1,"Full-port ID mismatch");
        read_reg(16'h0054,0,value);if(value!==68672) $fatal(1,"Image capacity mismatch");
        read_reg(16'h005c,0,value);if(value!==512) $fatal(1,"K capability mismatch");
        write_reg(4,1,15,0,2);
        write_reg(16'h004c,1,15,1,2);
        write_reg(16'h0020,65,15,0,2);
        write_reg(16'h0024,65,15,1,2);
        write_reg(16'h0028,513,15,0,2);
        write_reg(16'h0030,513,15,1,2);
        write_reg(16'h0034,3,15,0,2);
        write_reg(16'h0040,513,15,1,2);
        write_reg(16'h0044,1025,15,0,2);
        write_reg(16'h0048,0,15,0,0);
        write_reg(16'h004c,1,1,1,2);
        read_reg(16'h0048,0,value);if(value!==0) $fatal(1,"Partial write advanced upload");
        write_reg(4,1,15,0,2);
        for(job=0;job<JOB_COUNT;job=job+1) begin
            base=job*12;
            $readmemh($sformatf("jobs/%0d_input.hex",job),input_words);
            $readmemh($sformatf("jobs/%0d_golden.hex",job),golden);
            write_reg(16'h0048,0,15,job%3,0);
            read_reg(16'h4000,2,value);
            if(cfg[base+10]) begin
                for(j=0;j<68672;j=j+1) write_reg(16'h004c,input_words[j],15,j%3,0);
                read_reg(16'h0048,0,value);if(value!==68672) $fatal(1,"Upload cursor truncated");
                read_reg(16'h0050,0,value);if(value!==1) $fatal(1,"Input not ready");
                write_reg(16'h004c,1,15,0,2);
            end else begin
                // Simulation acceleration only: full compute/control/output
                // still execute below on the actual RTL for every job.
                @(negedge clk);fast_load=1;#1;
                for(rr=0;rr<64;rr=rr+1) dut.u_core.host_row_order[rr]=input_words[67584+rr];
                for(rr=0;rr<1024;rr=rr+1) dut.u_core.host_b_ptr[rr]=input_words[67648+rr];
                dut.u_ctrl.input_ready=1;dut.u_ctrl.upload_active=0;dut.u_ctrl.upload_next=68672;
                @(negedge clk);fast_load=0;
            end
            write_reg(16'h0020,cfg[base+0],15,0,0);
            write_reg(16'h0024,cfg[base+1],15,1,0);
            write_reg(16'h0028,cfg[base+2],15,2,0);
            write_reg(16'h002c,cfg[base+3],15,0,0);
            write_reg(16'h0030,cfg[base+4],15,1,0);
            write_reg(16'h0034,cfg[base+5],15,2,0);
            write_reg(16'h0038,cfg[base+6],15,0,0);
            write_reg(16'h003c,cfg[base+7],15,1,0);
            write_reg(16'h0040,cfg[base+8],15,2,0);
            write_reg(16'h0044,cfg[base+9],15,0,0);
            write_reg(4,1,15,2,0);
            write_reg(16'h0048,0,15,0,2);
            write_reg(16'h004c,1,15,1,2);
            write_reg(4,1,15,2,2);
            wait_done();if(value[2] || value[15:8]) $fatal(1,"Core error job=%0d status=%h",job,value);
            repeat(10) @(negedge clk);
            for(i=0;i<4096;i=i+1) begin
                read_reg(16'h4000+i*4,0,value);
                if(value!=={16'd0,golden[i]}) $fatal(1,"Mismatch job=%0d i=%0d got=%h want=%h",job,i,value,golden[i]);
            end
            read_reg(16'h0010,0,value);if(value!==job+1) $fatal(1,"Completion counter mismatch");
            if(cfg[base+11]) $display("FULL_CASE_PASS last_job=%0d",job);
        end
        @(negedge clk);rst_n=0;repeat(3) @(negedge clk);rst_n=1;repeat(5) @(negedge clk);
        write_reg(4,1,15,0,2);
        $display("FULL_RTL_PASS jobs=%0d checks=%0d",JOB_COUNT,checks);
        $finish;
    end
    initial begin #(64'd6000000000); $fatal(1,"Global timeout");end
endmodule
'''.replace('CONFIG_MAX',str(len(jobs)*12-1)).replace('JOB_COUNT',str(len(jobs)))
tb=stage/'sim/tb_sparse_matrix_full.sv';tb.write_text(header+body)
shutil.copyfile(tb,ROOT/('project/sim/tb_sparse_matrix_numeric.sv' if args.numerical_only else 'project/sim/tb_sparse_matrix_full.sv'))
files=[str(p.relative_to(stage)) for folder in ['src','board'] for p in (stage/folder).iterdir() if p.suffix in ('.sv','.v')]
tools=Path(os.environ.get('VIVADO_BIN','D:/Vivado/Vivado/2018.3/bin'))
def tool(name):return str(tools/(name+'.bat' if os.name=='nt' else name))
cmds=[('compile',[tool('xvlog'),'--sv','-i','src/inc',*files,str(tb.relative_to(stage))]),
      ('elaborate',[tool('xelab'),'tb_sparse_matrix_full','-s','sparse_matrix_full_sim','-mt','2']),
      ('run',[tool('xsim'),'sparse_matrix_full_sim','-runall'])]
passed=False
for name,cmd in cmds:
    print(name,'started',flush=True);start=time.monotonic()
    with (OUT/(name+'.log')).open('w',encoding='utf-8') as log:
        process=subprocess.Popen(cmd,cwd=stage,env=process_env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,errors='replace')
        tail=[]
        for line in process.stdout:
            log.write(line);log.flush();tail.append(line);tail=tail[-70:]
            if 'FULL_CASE_PASS' in line or 'FULL_RTL_PASS' in line:print(line.strip(),flush=True)
        code=process.wait()
    print(name,'exit',code,'seconds',round(time.monotonic()-start),flush=True)
    text=(OUT/(name+'.log')).read_text(encoding='utf-8')
    if code or 'ERROR:' in text or 'Fatal:' in text:
        print(''.join(tail),flush=True);break
    if name=='run':passed='FULL_RTL_PASS' in text
snapshot={str(p.relative_to(stage)):hashlib.sha256(p.read_bytes()).hexdigest()
          for folder in ['src','board'] for p in (stage/folder).rglob('*') if p.is_file()}
(OUT/'source_manifest.json').write_text(json.dumps(snapshot,indent=2))
(OUT/'summary.json').write_text(json.dumps(dict(passed=passed,original_cases=0 if args.numerical_only else 28,
    boundary_cases=4 if args.numerical_only else 2,jobs=len(jobs),axi_full_upload_jobs=sum(x['axi_upload'] for x in metadata),
    stage=str(stage),tool='Vivado 2018.3 xsim'),indent=2))
raise SystemExit(0 if passed else 1)
