`timescale 1ns/1ps
module tb_sparse_matrix_full;
    reg clk=0;always #10 clk=~clk;
    reg rst_n=0;
    reg [15:0] s_axi_awaddr=0,s_axi_araddr=0;
    reg [2:0] s_axi_awprot=0,s_axi_arprot=0;
    reg s_axi_awvalid=0,s_axi_wvalid=0,s_axi_bready=0,s_axi_arvalid=0,s_axi_rready=0;
    reg [31:0] s_axi_wdata=0;reg [3:0] s_axi_wstrb=0;
    wire s_axi_awready,s_axi_wready,s_axi_bvalid,s_axi_arready,s_axi_rvalid;
    wire [1:0] s_axi_bresp,s_axi_rresp;wire [31:0] s_axi_rdata;
    spmm_zcu104 dut(.*);
    integer checks=0,i,polls,fd,rc;
    reg [31:0] value;
    reg [15:0] golden[0:4095];
    reg held_b=0,held_r=0;reg [1:0] old_b,old_rr;reg [31:0] old_r;
    always @(posedge clk) begin
        if(!rst_n) begin held_b<=0;held_r<=0;end
        else begin
            if(held_b && (!s_axi_bvalid || s_axi_bresp!==old_b)) $fatal(1,"B changed under backpressure");
            if(held_r && (!s_axi_rvalid || s_axi_rdata!==old_r || s_axi_rresp!==old_rr)) $fatal(1,"R changed under backpressure");
            held_b<=s_axi_bvalid && !s_axi_bready;old_b<=s_axi_bresp;
            held_r<=s_axi_rvalid && !s_axi_rready;old_r<=s_axi_rdata;old_rr<=s_axi_rresp;
        end
    end
    task automatic send_aw(input [15:0] address);
        begin
            @(negedge clk);s_axi_awaddr=address;s_axi_awvalid=1;
            @(posedge clk);while(!s_axi_awready) @(posedge clk);
            @(negedge clk);s_axi_awvalid=0;
        end
    endtask
    task automatic send_w(input [31:0] data,input [3:0] strobe);
        begin
            @(negedge clk);s_axi_wdata=data;s_axi_wstrb=strobe;s_axi_wvalid=1;
            @(posedge clk);while(!s_axi_wready) @(posedge clk);
            @(negedge clk);s_axi_wvalid=0;
        end
    endtask
    task automatic write_reg(input [15:0] address,input [31:0] data,input [3:0] strobe,input integer order,input [1:0] expected);
        begin
            if(order==0) begin send_aw(address);repeat(3) @(negedge clk);send_w(data,strobe);end
            else if(order==1) begin send_w(data,strobe);repeat(3) @(negedge clk);send_aw(address);end
            else begin fork send_aw(address);send_w(data,strobe);join end
            while(!s_axi_bvalid) @(negedge clk);
            repeat(3) @(negedge clk);
            if(s_axi_bresp!==expected) $fatal(1,"Write %h response %d expected %d",address,s_axi_bresp,expected);
            s_axi_bready=1;@(posedge clk);@(negedge clk);s_axi_bready=0;checks=checks+1;
        end
    endtask
    task automatic read_reg(input [15:0] address,input [1:0] expected,output [31:0] data);
        begin
            @(negedge clk);s_axi_araddr=address;s_axi_arvalid=1;
            @(posedge clk);while(!s_axi_arready) @(posedge clk);
            @(negedge clk);s_axi_arvalid=0;
            while(!s_axi_rvalid) @(negedge clk);
            repeat(2) @(negedge clk);
            if(s_axi_rresp!==expected) $fatal(1,"Read %h response %d expected %d",address,s_axi_rresp,expected);
            data=s_axi_rdata;s_axi_rready=1;@(posedge clk);@(negedge clk);s_axi_rready=0;checks=checks+1;
        end
    endtask
    task automatic wait_done;
        begin
            polls=0;value=0;
            while(!value[1]) begin
                read_reg(16'h0008,0,value);polls=polls+1;
                if(polls>500000) $fatal(1,"Completion timeout");
            end
        end
    endtask

    reg [31:0] input_words[0:68671];
    reg [31:0] cfg[0:47];
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
        for(job=0;job<4;job=job+1) begin
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
        $display("FULL_RTL_PASS jobs=%0d checks=%0d",4,checks);
        $finish;
    end
    initial begin #(64'd6000000000); $fatal(1,"Global timeout");end
endmodule
