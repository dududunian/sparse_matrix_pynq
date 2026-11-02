"""Interactive PYNQ demonstrator; FPGA results never fall back to CPU."""
from pathlib import Path
import datetime,html,json,time,uuid
import numpy as np
import sparse_matrix as ns

STYLE='''<style>.ns-panel{font-family:Arial,"Microsoft YaHei",sans-serif;color:#16324a}.ns-hero{padding:24px;background:#102f46;color:white;border-radius:14px;margin:12px 0}.ns-hero h1{color:white;font-size:26px;margin:0 0 8px}.ns-cards{display:flex;gap:12px;flex-wrap:wrap}.ns-card{flex:1;min-width:210px;border:1px solid #dae5ec;padding:16px;border-radius:12px;background:#fff}.ns-muted{color:#5b7182;font-size:12px}.ns-metrics{display:flex;gap:12px;flex-wrap:wrap;margin:16px 0}.ns-metric{background:#eef5fa;padding:15px;border-radius:10px;min-width:145px}.ns-metric b{display:block;font-size:22px;color:#12394e}.ns-table td,.ns-table th{padding:4px 7px!important;text-align:right!important;border-bottom:1px solid #edf0f3}.ns-status{padding:12px;border-radius:8px;background:#eef5fa;margin:10px 0}</style>'''

def make_inputs(n=32,sparsity=90,seed=2026,preset='random'):
    if n not in [8,16,32,64,128]:raise ValueError('请选择支持的矩阵尺寸')
    if not 0<=sparsity<=100:raise ValueError('稀疏程度必须在 0–100%')
    rng=np.random.default_rng(seed)
    def random_matrix():
        data=np.zeros(n*n,dtype=np.float16)
        count=round(n*n*(100-sparsity)/100)
        values=np.array([-2,-1.5,-1,-.5,.5,1,1.5,2],dtype=np.float16)
        indices=rng.choice(n*n,count,replace=False)
        data[indices]=rng.choice(values,count)
        return data.reshape(n,n)
    a,b=random_matrix(),random_matrix()
    if preset=='identity':b=np.eye(n,dtype=np.float16)
    elif preset=='zero':b=np.zeros_like(a)
    elif preset=='same':b=a.copy()
    elif preset!='random':raise ValueError('未知输入类型')
    return a,b

def matrix_card(name,matrix):
    if matrix is None:return '<div class="ns-card"><h3>'+html.escape(name)+'</h3><p class="ns-muted">运行 FPGA 后显示结果</p></div>'
    matrix=np.asarray(matrix,dtype=float)
    n,m=matrix.shape;rr=np.linspace(0,n-1,min(n,32)).astype(int);cc=np.linspace(0,m-1,min(m,32)).astype(int)
    small=matrix[np.ix_(rr,cc)];scale=max(float(np.max(np.abs(matrix))),1e-9);rect=[]
    for i,row in enumerate(small):
        for j,v in enumerate(row):
            t=min(abs(float(v))/scale,1);color=('#%02x%02x%02x'%(int(245-210*t),int(248-91*t),int(250-119*t))) if v>=0 else ('#%02x%02x%02x'%(int(245-20*t),int(248-153*t),int(250-146*t)))
            rect.append(f'<rect x="{j}" y="{i}" width="1" height="1" fill="{color}"/>')
    svg=f'<svg role="img" aria-label="{html.escape(name)} 热力图" viewBox="0 0 {len(cc)} {len(rr)}" style="width:100%;max-height:240px;image-rendering:pixelated">'+''.join(rect)+'</svg>'
    rows=''.join('<tr>'+''.join(f'<td>{v:.3g}</td>' for v in row[:8])+'</tr>' for row in matrix[:8])
    note='全矩阵显示' if max(n,m)<=32 else '热力图采样至 32×32；校验仍覆盖全部输出'
    zeros=100*(1-np.count_nonzero(matrix)/matrix.size)
    return f'<div class="ns-card"><h3>{html.escape(name)} <small>{n}×{m}</small></h3>{svg}<p class="ns-muted">实际零元素 {zeros:.1f}% · 蓝色正值 / 橙色负值 · 白色为零<br>{note}，各图独立色阶</p><details><summary>查看左上角 8×8 数值</summary><table class="ns-table">{rows}</table></details></div>'

def run_case(acc,a,b,mode):
    started=time.perf_counter();ab,bb=ns.quantize(a),ns.quantize(b)
    ref_start=time.perf_counter();gold=ns.reference_bits(ab,bb,mode);reference_seconds=time.perf_counter()-ref_start
    bits,report=acc.calculate_bits(ab,bb,mode,expected=gold)
    if bits.shape!=gold.shape or bits.dtype!=np.uint16:raise RuntimeError('硬件返回的结果形状或类型不正确')
    mismatches=int(np.count_nonzero(bits!=gold))
    report=dict(report);report.update(passed=bool(report['passed'] and mismatches==0),logical_mismatches=mismatches,
        reference_seconds=reference_seconds,total_seconds=time.perf_counter()-started,
        upload_seconds=sum(t['upload_seconds'] for t in report['tile_results']),
        readback_seconds=sum(t['readback_seconds'] for t in report['tile_results']),
        backend='ZCU104 FPGA',image_id=hex(ns.IMAGE_ID))
    return bits,gold,report

def metrics_html(report):
    values=[('FPGA 计算',f"{report['pl_time_ms']:.3f} ms"),('输入上传',f"{report['upload_seconds']*1000:.1f} ms"),
      ('结果读回',f"{report['readback_seconds']*1000:.1f} ms"),('软件参考校验',f"{report['reference_seconds']*1000:.1f} ms"),
      ('本次总耗时',f"{report['total_seconds']*1000:.1f} ms")]
    return '<div class="ns-metrics">'+''.join(f'<div class="ns-metric"><span>{label}</span><b>{value}</b></div>' for label,value in values)+'</div><p class="ns-muted">总耗时从量化输入到结果核对结束，包含软件参考、数据打包、上传、等待与读回；不含首次加载硬件和页面绘图。FPGA 时间由周期计数和时钟寄存器读回计算，不能直接当作端到端加速比。</p>'

class Demo:
    def __init__(self,folder='.',accelerator_factory=None):
        import ipywidgets as w
        from IPython.display import display
        self.w=w;self.folder=Path(folder).resolve();self.acc=None;self.inputs=None;self.result=None
        self.factory=accelerator_factory
        self.mode=w.Dropdown(options=[('稀疏矩阵乘法','spmm'),('矩阵加法','add'),('矩阵减法','sub')],description='运算：')
        self.size=w.Dropdown(options=[8,16,32,64,128],value=32,description='尺寸：')
        self.sparse=w.IntSlider(min=0,max=100,step=5,value=90,description='零元素 %：',continuous_update=False)
        self.seed=w.BoundedIntText(value=2026,min=0,max=2147483647,description='随机种子：')
        self.preset=w.Dropdown(options=[('随机稀疏矩阵','random'),('B 为单位矩阵','identity'),('B 为零矩阵','zero'),('B 与 A 相同','same')],description='输入类型：')
        self.generate=w.Button(description='① 生成输入',button_style='info',icon='refresh')
        self.connect=w.Button(description='② 加载开发板',icon='plug')
        self.run=w.Button(description='③ 开始 FPGA 计算',button_style='success',icon='play',disabled=True)
        self.save=w.Button(description='保存本次结果',icon='save',disabled=True)
        self.state=w.HTML();self.matrices=w.HTML();self.metrics=w.HTML();self.saved=w.HTML()
        self.controls=[self.mode,self.size,self.sparse,self.seed,self.preset,self.generate,self.connect,self.run,self.save]
        for control in self.controls[:5]:control.observe(self._invalidate,names='value')
        self.generate.on_click(self._generate);self.connect.on_click(self._connect);self.run.on_click(self._run);self.save.on_click(self._save)
        self.widget=w.VBox([w.HTML(STYLE+'<div class="ns-hero"><div>PYNQ × ZCU104 · FPGA 实时计算</div><h1>稀疏矩阵计算平台</h1><div>选择矩阵，运行硬件，核对每一个结果。</div></div>'),
            w.HBox([self.mode,self.size],layout=w.Layout(flex_flow='row wrap')),
            w.HBox([self.sparse,self.seed],layout=w.Layout(flex_flow='row wrap')),self.preset,
            w.HBox([self.generate,self.connect,self.run,self.save],layout=w.Layout(flex_flow='row wrap')),
            self.state,self.metrics,self.matrices,self.saved])
        self._generate();self._status('输入已生成。开发板尚未加载；请先点击“加载开发板”。')
    def _status(self,text,bad=False):
        color='#fff0ed' if bad else '#eef5fa'
        self.state.value=f'<div class="ns-status" style="background:{color}">{html.escape(text)}</div>'
    def _busy(self,value):
        for control in self.controls:control.disabled=value
        if not value:
            self.run.disabled=self.acc is None or self.inputs is None
            self.save.disabled=self.result is None
    def _invalidate(self,*_):
        self.inputs=None;self.result=None;self.run.disabled=True;self.save.disabled=True
        self.metrics.value='';self.matrices.value='';self.saved.value=''
        self._status('参数已改变，请重新生成输入矩阵。')
    def _draw(self,c=None):
        a,b=self.inputs
        self.matrices.value='<div class="ns-panel ns-cards">'+matrix_card('输入 A',a)+matrix_card('输入 B',b)+matrix_card('结果 C',c)+'</div>'
    def _generate(self,*_):
        self.inputs=make_inputs(self.size.value,self.sparse.value,self.seed.value,self.preset.value)
        self.result=None;self.metrics.value='';self.saved.value='';self.save.disabled=True
        self.run.disabled=self.acc is None;self._draw();self._status('输入已生成，可以加载开发板或开始计算。')
    def _connect(self,*_):
        self._busy(True);self.acc=None;self.result=None;self.metrics.value='';self.saved.value=''
        if self.inputs is not None:self._draw()
        try:
            self._status('正在检查文件并加载 FPGA，请等待……')
            if self.factory is None:
                import platform
                model=Path('/proc/device-tree/model')
                if platform.machine()!='aarch64' or not model.exists() or b'ZCU104' not in model.read_bytes():
                    raise RuntimeError('请在 ZCU104 的 Jupyter 中加载硬件；电脑可生成输入，但不能运行 FPGA。')
                self.acc=ns.Accelerator(self.folder)
            else:self.acc=self.factory(self.folder)
            self._status('开发板已加载，时钟读回 %.3f MHz。可以开始计算。'%(self.acc.clock_hz/1e6))
        except Exception as e:self._status('加载失败：'+str(e),True)
        finally:self._busy(False)
    def _run(self,*_):
        if self.acc is None or self.inputs is None:return
        self._busy(True);self.result=None;self.metrics.value='';self.saved.value='';self._draw()
        try:
            self._status('正在生成 FP16 参考结果、传输矩阵并运行 FPGA，请等待……')
            bits,gold,report=run_case(self.acc,*self.inputs,self.mode.value)
            self.result=(bits,gold,report);self._draw(bits.view(np.float16));self.metrics.value=metrics_html(report)
            if report['passed']:self._status(f"校验通过 · 全部输出逐 bit 一致 · {report['tiles']} 个硬件任务")
            else:self._status(f"校验未通过 · 物理输出不匹配 {report['mismatches']}，逻辑输出不匹配 {report['logical_mismatches']}。请保存结果。",True)
        except Exception as e:
            self.acc=None;self.result=None;self._status('计算失败：'+str(e)+' 请重新加载开发板。',True)
        finally:self._busy(False)
    def _save(self,*_):
        if self.result is None:return
        try:
            bits,gold,report=self.result;name=datetime.datetime.now().strftime('%Y%m%d_%H%M%S')+'_'+uuid.uuid4().hex[:6]
            out=self.folder/'demo_results'/name;out.mkdir(parents=True)
            params=dict(size=self.size.value,sparsity=self.sparse.value,seed=self.seed.value,preset=self.preset.value,mode=self.mode.value)
            (out/'report.json').write_text(json.dumps(dict(parameters=params,report=report),indent=2),encoding='utf-8')
            np.savez_compressed(out/'matrices.npz',A=self.inputs[0],B=self.inputs[1],C_bits=bits,golden_bits=gold)
            self.saved.value='<p>已保存到 <b>'+html.escape(str(out.relative_to(self.folder)))+'</b>，可在 Jupyter 文件列表中下载 report.json 和 matrices.npz。</p>'
        except Exception as e:self._status('保存失败：'+str(e),True)
    def show(self):
        from IPython.display import display
        display(self.widget)
        return self