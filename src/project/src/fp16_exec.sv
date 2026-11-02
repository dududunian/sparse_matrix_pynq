`timescale 1ns/1ps
`default_nettype none
// Binary16 add/sub/mul. RNE, gradual underflow, finite overflow saturates.
// Canonical NaN=7e00; each operation rounds separately (no fused MAC).
// Correctness-first implementation: fixed integer datapaths and bounded loops.
module fp16_exec #(
    parameter integer LATENCY = 2
) (
    input wire clk, rst_n,
    input wire req_valid,
    output wire req_ready,
    input wire [1:0] req_op, // 0:add, 1:sub, 2:mul; 3:canonical NaN
    input wire [15:0] req_a, req_b,
    output reg rsp_valid,
    input wire rsp_ready,
    output reg [15:0] rsp_result
);
    reg busy;
    // LATENCY>=2: isolate the asynchronous FIFO read from arithmetic.
    reg [1:0] operand_op;
    reg [15:0] operand_a, operand_b;
    localparam integer COUNT_W = (LATENCY < 2) ? 1 : $clog2(LATENCY+1);
    reg [COUNT_W-1:0] remaining;
    assign req_ready = !busy && !rsp_valid;

    function automatic [43:0] rounded_shift;
        input [42:0] mag;
        input integer amount;
        reg [43:0] value, truncated, residue, half, mask;
        begin
            value = {1'b0,mag};
            if (amount <= 0) rounded_shift = value << (-amount);
            else if (amount >= 44) rounded_shift = 0;
            else begin
                truncated = value >> amount;
                half = 44'd1 << (amount-1);
                mask = (44'd1 << amount)-1;
                residue = value & mask;
                rounded_shift = truncated + ((residue > half) || ((residue == half) && truncated[0]));
            end
        end
    endfunction

    function automatic [15:0] pack_finite;
        input sign_bit;
        input [42:0] mag;
        input integer scale; // exact value = mag * 2**scale (integer shifts only)
        integer highest, j, exponent;
        reg [43:0] significand;
        reg [4:0] biased;
        begin
            highest = -1;
            for (j=0;j<43;j=j+1) if (mag[j]) highest=j;
            exponent = highest + scale;
            significand = 0;
            biased = 0;
            if (highest < 0) pack_finite = {sign_bit,15'd0};
            else if (exponent > 15) pack_finite = {sign_bit,15'h7bff};
            else if (exponent < -14) begin
                significand = rounded_shift(mag,-24-scale);
                if (significand >= 1024) pack_finite = {sign_bit,5'd1,10'd0};
                else pack_finite = {sign_bit,5'd0,significand[9:0]};
            end else begin
                significand = rounded_shift(mag,highest-10);
                if (significand >= 2048) begin
                    significand = significand >> 1;
                    exponent = exponent+1;
                end
                biased = exponent+15;
                if (exponent > 15) pack_finite = {sign_bit,15'h7bff};
                else pack_finite = {sign_bit,biased,significand[9:0]};
            end
        end
    endfunction

    function automatic [15:0] calculate;
        input [1:0] op;
        input [15:0] a,b;
        reg sa,sb,sr,na,nb,ia,ib,za,zb;
        reg [4:0] ea,eb;
        reg [10:0] ma,mb;
        reg [21:0] product;
        reg [42:0] va,vb,mag;
        integer shift_a,shift_b,scale;
        begin
            sa=a[15]; sb=b[15] ^ (op==1);
            ea=a[14:10]; eb=b[14:10];
            na=(ea==31)&&(a[9:0]!=0); nb=(eb==31)&&(b[9:0]!=0);
            ia=(ea==31)&&(a[9:0]==0); ib=(eb==31)&&(b[9:0]==0);
            za=(a[14:0]==0); zb=(b[14:0]==0);
            ma={(ea!=0),a[9:0]}; mb={(eb!=0),b[9:0]};
            va=0; vb=0; mag=0; product=0; sr=0;
            shift_a=(ea==0)?0:ea-1; shift_b=(eb==0)?0:eb-1;
            scale=-24;
            if (na || nb || op==3) calculate=16'h7e00;
            else if (op==2) begin
                sr=a[15]^b[15];
                if ((ia&&zb)||(ib&&za)) calculate=16'h7e00;
                else if (ia||ib) calculate={sr,5'd31,10'd0};
                else begin
                    product=ma*mb;
                    scale=((ea==0)?-24:ea-25)+((eb==0)?-24:eb-25);
                    calculate=pack_finite(sr,{21'd0,product},scale);
                end
            end else if (ia && ib && (sa!=sb)) calculate=16'h7e00;
            else if (ia) calculate={sa,5'd31,10'd0};
            else if (ib) calculate={sb,5'd31,10'd0};
            else begin
                va={32'd0,ma} << shift_a;
                vb={32'd0,mb} << shift_b;
                if (sa==sb) begin mag=va+vb; sr=sa; end
                else if (va>vb) begin mag=va-vb; sr=sa; end
                else if (vb>va) begin mag=vb-va; sr=sb; end
                else begin mag=0; sr=0; end
                calculate=pack_finite(sr,mag,-24);
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy<=0; remaining<=0; rsp_valid<=0; rsp_result<=0;
            operand_op<=0; operand_a<=0; operand_b<=0;
        end else begin
            if (rsp_valid && rsp_ready) rsp_valid<=0;
            if (req_valid && req_ready) begin
                if (LATENCY <= 1) begin
                    rsp_result<=calculate(req_op,req_a,req_b);
                    rsp_valid<=1;
                end else begin
                    operand_op<=req_op; operand_a<=req_a; operand_b<=req_b;
                    busy<=1; remaining<=LATENCY-1;
                end
            end else if (busy) begin
                if (remaining == LATENCY-1)
                    rsp_result<=calculate(operand_op,operand_a,operand_b);
                if (remaining==1) begin busy<=0; remaining<=0; rsp_valid<=1; end
                else remaining<=remaining-1'b1;
            end
        end
    end
endmodule
`default_nettype wire
