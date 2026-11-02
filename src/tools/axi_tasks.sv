`timescale 1ns/1ps
module tb_spmm_axi;
    reg clk=0;always #5 clk=~clk;
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
                if(polls>10000) $fatal(1,"Completion timeout");
            end
        end
    endtask
