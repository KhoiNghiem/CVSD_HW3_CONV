module decode_barcode(
    input wire i_clk,
    input wire i_rst_n,
    input wire [56:0] i_ref_barcode,
    input wire i_is_decode_barcode_state,

    output wire [7:0] kernel_size,
    output wire [7:0] stride_size,
    output wire [7:0] dilation_size,
    output reg o_out_valid1_r,
    output reg o_out_valid2_r,
    output reg o_out_valid3_r
);

    // Các đoạn cố định
    wire [10:0] start_code;
    wire [12:0] end_code;
    wire [10:0] data1_code;
    wire [10:0] data2_code;
    wire [10:0] data3_code;

    assign start_code  = i_ref_barcode[56:46];
    assign data1_code  = i_ref_barcode[45:35];
    assign data2_code  = i_ref_barcode[34:24];
    assign data3_code  = i_ref_barcode[23:13];
    assign end_code    = i_ref_barcode[12:0];

    reg [7:0] k_tmp, s_tmp, d_tmp;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
			k_tmp 		  <= 0;
			s_tmp 		  <= 0;
			d_tmp 		  <= 0;
        end 
        else begin 
            if (i_is_decode_barcode_state) begin
                // --- Start/End code check ---
                if ((start_code != 11'b11010011100) || (end_code != 13'b1100011101011)) begin
                    k_tmp <= 8'd0;
                    s_tmp <= 8'd0;
                    d_tmp <= 8'd0;
                end 
                else begin
                    // --- Giải mã từng pattern ---
                    case (data1_code)
                        11'b11001101100: k_tmp <= 8'd1;
                        11'b11001100110: k_tmp <= 8'd2;
                        11'b10010011000: k_tmp <= 8'd3;
                        default:          k_tmp <= 8'd0;
                    endcase

                    case (data2_code)
                        11'b11001101100: s_tmp <= 8'd1;
                        11'b11001100110: s_tmp <= 8'd2;
                        11'b10010011000: s_tmp <= 8'd3;
                        default:          s_tmp <= 8'd0;
                    endcase

                    case (data3_code)
                        11'b11001101100: d_tmp <= 8'd1;
                        11'b11001100110: d_tmp <= 8'd2;
                        11'b10010011000: d_tmp <= 8'd3;
                        default:          d_tmp <= 8'd0;
                    endcase
                end

            end
        end
    end

    assign kernel_size      = ((k_tmp != 8'd0) && (s_tmp != 8'd0) && (d_tmp != 8'd0)) ? k_tmp : 8'd0;
    assign stride_size      = ((k_tmp != 8'd0) && (s_tmp != 8'd0) && (d_tmp != 8'd0)) ? s_tmp : 8'd0;
    assign dilation_size    = ((k_tmp != 8'd0) && (s_tmp != 8'd0) && (d_tmp != 8'd0)) ? d_tmp : 8'd0;

    // --- valid output delay ---
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_out_valid1_r <= 1'b0;
            o_out_valid2_r <= 1'b0;
            o_out_valid3_r <= 1'b0;
        end else begin
            o_out_valid1_r <= i_is_decode_barcode_state;
            o_out_valid2_r <= i_is_decode_barcode_state;
            o_out_valid3_r <= i_is_decode_barcode_state;
        end
    end

endmodule
