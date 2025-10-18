module decode_barcode(
    input wire i_clk,
    input wire i_rst_n,
    input wire [56:0] i_ref_barcode,
    input wire i_is_decode_barcode_state,

    output reg [7:0] kernel_size,
    output reg [7:0] stride_size,
    output reg [7:0] dilation_size,
    output reg o_out_valid1_r,
    output reg o_out_valid2_r,
    output reg o_out_valid3_r
);

// Các đoạn cố định
	wire [10:0] start_code;
	wire [10:0] data1_code;
	wire [10:0] data2_code;
	wire [10:0] data3_code;

    assign start_code  = i_ref_barcode[56:46];
	assign data1_code  = i_ref_barcode[45:35];
	assign data2_code  = i_ref_barcode[34:24];
	assign data3_code  = i_ref_barcode[23:13];

    always @(posedge i_clk or negedge i_rst_n) begin
		if (!i_rst_n) begin
			kernel_size <= 0;
			stride_size <= 0;
			dilation_size <= 0;
		end
		else if (i_is_decode_barcode_state) begin		// i_is_decode_barcode_state
			
			// Start code check
			if (start_code != 11'b11010011100) begin
				kernel_size <= 0;  // báo lỗi StartCode
				stride_size <= 0;  // báo lỗi StartCode
				dilation_size <= 0;  // báo lỗi StartCode
			end
			else begin
				// Giải mã từng pattern 11-bit
				case (data1_code)
					11'b11001101100: kernel_size <= 8'd1;  // "01"
					11'b11001100110: kernel_size <= 8'd2;
					11'b10010011000: kernel_size <= 8'd3;
					default: kernel_size <= 8'hFF;
				endcase

				case (data2_code)
					11'b11001101100: stride_size <= 8'd1;
					11'b11001100110: stride_size <= 8'd2;
					11'b10010011000: stride_size <= 8'd3;
					default: stride_size <= 8'hFF;
				endcase

				case (data3_code)
					11'b11001101100: dilation_size <= 8'd1;
					11'b11001100110: dilation_size <= 8'd2;
					11'b10010011000: dilation_size <= 8'd3;
					default: dilation_size <= 8'hFF;
				endcase
			end
		end
	end

    always @(posedge i_clk or negedge i_rst_n) begin
		if (!i_rst_n) begin
			o_out_valid1_r <= 1'b0;
			o_out_valid2_r <= 1'b0;
			o_out_valid3_r <= 1'b0;
		end
		else begin
			// Delay valid by 1 cycle so it aligns with registered data
			o_out_valid1_r <= i_is_decode_barcode_state;		// i_is_decode_barcode_state
			o_out_valid2_r <= i_is_decode_barcode_state;		// i_is_decode_barcode_state
			o_out_valid3_r <= i_is_decode_barcode_state;		// i_is_decode_barcode_state
		end
	end

endmodule