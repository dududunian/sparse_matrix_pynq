`timescale 1ns/1ps
`default_nettype none
// Single-outstanding AXI4-Lite slave. AW and W are captured independently.
module spmm_axi_ctrl (
    input wire clk, rst_n,
    input wire [15:0] s_axi_awaddr,
    input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid, output wire s_axi_awready,
    input wire [31:0] s_axi_wdata, input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid, output wire s_axi_wready,
    output reg [1:0] s_axi_bresp, output reg s_axi_bvalid,
    input wire s_axi_bready,
    input wire [15:0] s_axi_araddr, input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid, output wire s_axi_arready,
    output reg [31:0] s_axi_rdata, output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid, input wire s_axi_rready,
    output reg upload_we,
    output reg [16:0] upload_index,
    output reg [31:0] upload_data,
    output reg core_start, input wire core_busy, core_done,
    input wire [7:0] core_error_code,
    output reg [15:0] cfg_m, cfg_n, cfg_k, cfg_block_vecs,
    output reg [9:0] cfg_a_vec_count, cfg_b_spmm_ptr_base, cfg_b_add_ptr_base,
    output reg [1:0] cfg_pe_mode,
    output reg [31:0] cfg_b_chunk_count, cfg_b_ptr_count,
    output wire dbg_c_en, output reg [11:0] dbg_c_addr,
    input wire [15:0] dbg_c_dout
);
    reg aw_pending,w_pending;
    reg [15:0] awaddr;
    reg [31:0] wdata;
    reg [3:0] wstrb;
    reg running,done_sticky;
    reg input_ready,upload_active;
    reg [16:0] upload_next;
    reg [7:0] error_latched;
    reg [2:0] cooldown;
    reg [31:0] cycles,last_cycles,completed;
    reg [1:0] read_state;
    wire host_read_pending = read_state!=0 || s_axi_rvalid || (s_axi_arvalid && s_axi_arready);
    wire unavailable=running || core_busy || core_done || cooldown!=0;
    assign s_axi_awready=!aw_pending && !s_axi_bvalid;
    assign s_axi_wready=!w_pending && !s_axi_bvalid;
    assign s_axi_arready=!s_axi_rvalid && read_state==0;
    assign dbg_c_en=read_state==1;
    function automatic [31:0] merge_bytes;
        input [31:0] old_value,new_value;
        input [3:0] strobes;
        integer i;
        begin
            merge_bytes=old_value;
            for(i=0;i<4;i=i+1) if(strobes[i]) merge_bytes[i*8+:8]=new_value[i*8+:8];
        end
    endfunction
    reg [31:0] merged;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            aw_pending<=0;w_pending<=0;awaddr<=0;wdata<=0;wstrb<=0;
            s_axi_bvalid<=0;s_axi_bresp<=0;s_axi_rvalid<=0;s_axi_rresp<=0;s_axi_rdata<=0;
            upload_we<=0;upload_index<=0;upload_data<=0;upload_next<=0;input_ready<=0;upload_active<=0;
            core_start<=0;running<=0;done_sticky<=0;error_latched<=0;cooldown<=3;
            cycles<=0;last_cycles<=0;completed<=0;read_state<=0;dbg_c_addr<=0;
            cfg_m<=64;cfg_n<=64;cfg_k<=64;cfg_block_vecs<=8;cfg_a_vec_count<=25;
            cfg_b_spmm_ptr_base<=0;cfg_b_add_ptr_base<=0;cfg_pe_mode<=0;
            cfg_b_chunk_count<=64;cfg_b_ptr_count<=65;
        end else begin
            upload_we<=0;
            core_start<=0;
            if(cooldown!=0) cooldown<=cooldown-1'b1;
            if(running) cycles<=cycles+1'b1;
            if(core_done && running) begin
                running<=0;done_sticky<=1;error_latched<=core_error_code;
                last_cycles<=cycles+1'b1;completed<=completed+1'b1;cooldown<=3;
            end
            if(s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
            if(s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
            if(s_axi_awvalid && s_axi_awready) begin awaddr<=s_axi_awaddr;aw_pending<=1;end
            if(s_axi_wvalid && s_axi_wready) begin wdata<=s_axi_wdata;wstrb<=s_axi_wstrb;w_pending<=1;end
            if(aw_pending && w_pending && !s_axi_bvalid) begin
                aw_pending<=0;w_pending<=0;s_axi_bvalid<=1;s_axi_bresp<=0;
                if(awaddr[1:0]!=0) s_axi_bresp<=2;
                else if(awaddr==16'h0004) begin
                    if(wstrb[0]) begin
                        if(wdata[0]) begin
                            if(unavailable || upload_we || !input_ready || host_read_pending) s_axi_bresp<=2;
                            else begin core_start<=1;running<=1;done_sticky<=0;error_latched<=0;cycles<=0;end
                        end else if(wdata[1]) begin
                            if(unavailable) s_axi_bresp<=2;
                            else begin done_sticky<=0;error_latched<=0;end
                        end
                    end
                end else if(unavailable) s_axi_bresp<=2;
                else case(awaddr)
                    // Begin a complete replacement image. Old results become invalid.
                    16'h0048: begin
                        if(wstrb!=15 || wdata!=0 || host_read_pending || upload_we) s_axi_bresp<=2;
                        else begin upload_next<=0;upload_active<=1;input_ready<=0;done_sticky<=0;error_latched<=0;end
                    end
                    // Full 32-bit writes only; exactly 68672 sequential words.
                    16'h004c: begin
                        if(wstrb!=15 || !upload_active || upload_next>=68672) s_axi_bresp<=2;
                        else begin
                            upload_we<=1;upload_index<=upload_next;upload_data<=wdata;
                            upload_next<=upload_next+1'b1;
                            if(upload_next==68671) begin upload_active<=0;input_ready<=1;end
                        end
                    end
                    16'h0020: begin merged=merge_bytes({16'd0,cfg_m},wdata,wstrb);if(merged>64) s_axi_bresp<=2;else cfg_m<=merged[15:0];end
                    16'h0024: begin merged=merge_bytes({16'd0,cfg_n},wdata,wstrb);if(merged>64) s_axi_bresp<=2;else cfg_n<=merged[15:0];end
                    16'h0028: begin merged=merge_bytes({16'd0,cfg_k},wdata,wstrb);if(merged>512) s_axi_bresp<=2;else cfg_k<=merged[15:0];end
                    16'h002c: begin merged=merge_bytes({16'd0,cfg_block_vecs},wdata,wstrb);if(merged>32) s_axi_bresp<=2;else cfg_block_vecs<=merged[15:0];end
                    16'h0030: begin merged=merge_bytes({22'd0,cfg_a_vec_count},wdata,wstrb);if(merged>512) s_axi_bresp<=2;else cfg_a_vec_count<=merged[9:0];end
                    16'h0034: begin merged=merge_bytes({30'd0,cfg_pe_mode},wdata,wstrb);if(merged>2) s_axi_bresp<=2;else cfg_pe_mode<=merged[1:0];end
                    16'h0038: begin merged=merge_bytes({22'd0,cfg_b_spmm_ptr_base},wdata,wstrb);if(merged>1023) s_axi_bresp<=2;else cfg_b_spmm_ptr_base<=merged[9:0];end
                    16'h003c: begin merged=merge_bytes({22'd0,cfg_b_add_ptr_base},wdata,wstrb);if(merged>1023) s_axi_bresp<=2;else cfg_b_add_ptr_base<=merged[9:0];end
                    16'h0040: begin merged=merge_bytes(cfg_b_chunk_count,wdata,wstrb);if(merged>512) s_axi_bresp<=2;else cfg_b_chunk_count<=merged;end
                    16'h0044: begin merged=merge_bytes(cfg_b_ptr_count,wdata,wstrb);if(merged>1024) s_axi_bresp<=2;else cfg_b_ptr_count<=merged;end
                    default:s_axi_bresp<=2;
                endcase
            end
            if(s_axi_arvalid && s_axi_arready) begin
                s_axi_rdata<=0;s_axi_rresp<=0;
                if(s_axi_araddr[1:0]!=0) begin s_axi_rvalid<=1;s_axi_rresp<=2;end
                else if(s_axi_araddr>=16'h4000 && s_axi_araddr<16'h8000) begin
                    if(unavailable || !done_sticky || error_latched!=0) begin s_axi_rvalid<=1;s_axi_rresp<=2;end
                    else begin dbg_c_addr<=s_axi_araddr[13:2];read_state<=1;end
                end else begin
                    s_axi_rvalid<=1;
                    case(s_axi_araddr)
                        16'h0000:s_axi_rdata<=32'h53504d31;
                        16'h0004:s_axi_rdata<=0;
                        16'h0008:s_axi_rdata<={16'd0,error_latched,5'd0,(error_latched!=0),done_sticky,unavailable};
                        16'h000c:s_axi_rdata<=last_cycles;
                        16'h0010:s_axi_rdata<=completed;
                        16'h0014:s_axi_rdata<=32'h4e533201;
                        16'h0020:s_axi_rdata<={16'd0,cfg_m};
                        16'h0024:s_axi_rdata<={16'd0,cfg_n};
                        16'h0028:s_axi_rdata<={16'd0,cfg_k};
                        16'h002c:s_axi_rdata<={16'd0,cfg_block_vecs};
                        16'h0030:s_axi_rdata<={22'd0,cfg_a_vec_count};
                        16'h0034:s_axi_rdata<={30'd0,cfg_pe_mode};
                        16'h0038:s_axi_rdata<={22'd0,cfg_b_spmm_ptr_base};
                        16'h003c:s_axi_rdata<={22'd0,cfg_b_add_ptr_base};
                        16'h0040:s_axi_rdata<=cfg_b_chunk_count;
                        16'h0044:s_axi_rdata<=cfg_b_ptr_count;
                        16'h0048:s_axi_rdata<={15'd0,upload_next};
                        16'h0050:s_axi_rdata<={30'd0,upload_active,input_ready};
                        16'h0054:s_axi_rdata<=68672;
                        16'h0058:s_axi_rdata<=64;
                        16'h005c:s_axi_rdata<=512;
                        16'h0060:s_axi_rdata<=7;
                        default:s_axi_rresp<=2;
                    endcase
                end
            end
            if(read_state==1) read_state<=2;
            else if(read_state==2) begin
                s_axi_rdata<={16'd0,dbg_c_dout};s_axi_rresp<=0;s_axi_rvalid<=1;read_state<=0;
            end
        end
    end
endmodule
`default_nettype wire
