`timescale 1ns/1ps
`default_nettype none
// ZCU104 bring-up image: software-loaded input, AXI-Lite command and result window.
module spmm_zcu104 (
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 clk CLK", X_INTERFACE_PARAMETER="ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET rst_n, FREQ_HZ 50000000" *)
    input wire clk,
    (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 rst_n RST", X_INTERFACE_PARAMETER="POLARITY ACTIVE_LOW" *)
    input wire rst_n,
    input wire [15:0] s_axi_awaddr, input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid, output wire s_axi_awready,
    input wire [31:0] s_axi_wdata, input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid, output wire s_axi_wready,
    output wire [1:0] s_axi_bresp, output wire s_axi_bvalid, input wire s_axi_bready,
    input wire [15:0] s_axi_araddr, input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid, output wire s_axi_arready,
    output wire [31:0] s_axi_rdata, output wire [1:0] s_axi_rresp,
    output wire s_axi_rvalid, input wire s_axi_rready
);
    wire upload_we;
    wire [16:0] upload_index;
    wire [31:0] upload_data;
    wire core_start,core_busy,core_done,core_error,dbg_c_en;
    wire [7:0] core_error_code;
    wire [15:0] cfg_m,cfg_n,cfg_k,cfg_block_vecs,dbg_c_dout;
    wire [9:0] cfg_a_vec_count,cfg_b_spmm_ptr_base,cfg_b_add_ptr_base;
    wire [1:0] cfg_pe_mode;
    wire [31:0] cfg_b_chunk_count,cfg_b_ptr_count;
    wire [11:0] dbg_c_addr;
    spmm_axi_ctrl u_ctrl(.clk(clk),.rst_n(rst_n),.s_axi_awaddr(s_axi_awaddr),.s_axi_awprot(s_axi_awprot),.s_axi_awvalid(s_axi_awvalid),.s_axi_awready(s_axi_awready),.s_axi_wdata(s_axi_wdata),.s_axi_wstrb(s_axi_wstrb),.s_axi_wvalid(s_axi_wvalid),.s_axi_wready(s_axi_wready),.s_axi_bresp(s_axi_bresp),.s_axi_bvalid(s_axi_bvalid),.s_axi_bready(s_axi_bready),.s_axi_araddr(s_axi_araddr),.s_axi_arprot(s_axi_arprot),.s_axi_arvalid(s_axi_arvalid),.s_axi_arready(s_axi_arready),.s_axi_rdata(s_axi_rdata),.s_axi_rresp(s_axi_rresp),.s_axi_rvalid(s_axi_rvalid),.s_axi_rready(s_axi_rready),.upload_we(upload_we),.upload_index(upload_index),.upload_data(upload_data),.core_start(core_start),.core_busy(core_busy),.core_done(core_done),.core_error_code(core_error_code),.cfg_m(cfg_m),.cfg_n(cfg_n),.cfg_k(cfg_k),.cfg_block_vecs(cfg_block_vecs),.cfg_a_vec_count(cfg_a_vec_count),.cfg_b_spmm_ptr_base(cfg_b_spmm_ptr_base),.cfg_b_add_ptr_base(cfg_b_add_ptr_base),.cfg_pe_mode(cfg_pe_mode),.cfg_b_chunk_count(cfg_b_chunk_count),.cfg_b_ptr_count(cfg_b_ptr_count),.dbg_c_en(dbg_c_en),.dbg_c_addr(dbg_c_addr),.dbg_c_dout(dbg_c_dout));
    top #(.M_MAX(64),.N_MAX(64),.K_MAX(512),
        .A_VEC_DEPTH(512),.A_VEC_ADDR_W(9),.B_VAL_DEPTH(512),.B_VAL_ADDR_W(9),
        .B_PTR_DEPTH(1024),.B_PTR_ADDR_W(10),.C_DEPTH(4096),.C_ADDR_W(12),
        .PE_BUF_DEPTH(64),.PE_BUF_ADDR_W(6)) u_core(
        .clk(clk),.rst_n(rst_n),.start(core_start),
        .upload_we(upload_we),.upload_index(upload_index),.upload_data(upload_data),
        .cfg_m(cfg_m),.cfg_n(cfg_n),.cfg_k(cfg_k),.cfg_block_vecs(cfg_block_vecs),
        .cfg_a_vec_count(cfg_a_vec_count),.cfg_pe_mode(cfg_pe_mode),
        .cfg_b_spmm_ptr_base(cfg_b_spmm_ptr_base),.cfg_b_add_ptr_base(cfg_b_add_ptr_base),
        .cfg_b_chunk_count(cfg_b_chunk_count),.cfg_b_ptr_count(cfg_b_ptr_count),
        .busy(core_busy),.done(core_done),.error(core_error),.error_code(core_error_code),
        .dbg_c_en(dbg_c_en),.dbg_c_addr(dbg_c_addr),.dbg_c_dout(dbg_c_dout));
endmodule
`default_nettype wire
