
module core (                       //Don't modify interface
	input      		i_clk,
	input      		i_rst_n,
	input    	  	i_in_valid,
	input 	[31: 0] i_in_data,

	output			o_in_ready,

	output	[ 7: 0]	o_out_data1,	//  Kernel size
	output	[ 7: 0]	o_out_data2,	//	Stride size
	output	[ 7: 0]	o_out_data3,	//	 Dilation size
	output	[ 7: 0]	o_out_data4,	//

	output	[11: 0] o_out_addr1,
	output	[11: 0] o_out_addr2,
	output	[11: 0] o_out_addr3,
	output	[11: 0] o_out_addr4,

	output 			o_out_valid1,
	output 			o_out_valid2,
	output 			o_out_valid3,
	output 			o_out_valid4,

	output 			o_exe_finish
);
	
	reg [11:0] img_cnt;
	reg o_in_ready_r;
	reg bank_sel;           // chọn bank 0 hoặc 1
	reg [63:0] lsb_matrix [0:63]; // row-major order
	reg barcode_found;

	wire [8:0] addr_in_bank = img_cnt[8:0]; // địa chỉ trong bank (0–511)
	wire is_load_img_state, is_find_barcode_state, is_decode_barcode_state, is_load_weight_state;
	wire decode_finish;

	assign o_in_ready = o_in_ready_r;

	reg [5:0] row_cnt;       // 0 ~ 63
	reg [5:0] row_cnt_next;       // 0 ~ 63
	reg [3:0] col_word_cnt;  // 0 ~ 15 (mỗi word chứa 4 pixel)
	reg [3:0] col_word_cnt_next;  // 0 ~ 15 (mỗi word chứa 4 pixel)
	wire [5:0] col_base;     // pixel index trong hàng
	assign col_base = {col_word_cnt, 2'b00}; // col_word_cnt * 4

	wire [3:0] lsb_bits;
	assign lsb_bits = { i_in_data[24], i_in_data[16], i_in_data[8], i_in_data[0] };
	integer j;

	reg [1:0] weight_cnt;     // 0→1→2 → hết 3 chu kỳ
	reg [3:0] weight_index;    // 0..8
	reg       weight_done;

	controller u_controller(
		.i_clk(i_clk),
		.i_rst_n(i_rst_n),
		.i_in_valid(i_in_valid),
		.i_barcode_found(barcode_found),
		.i_load_weight_done(weight_done),
		.i_o_exe_finish(o_exe_finish),

		.is_load_img_state(is_load_img_state),
		.is_find_barcode_state(is_find_barcode_state),
		.is_decode_barcode_state(is_decode_barcode_state),
		.is_load_weight_state(is_load_weight_state)
	);

		// 9 trọng số, mỗi cái 8-bit signed fixed-point
	reg signed [7:0] weight_reg [0:8];  

	always @(posedge i_clk or negedge i_rst_n) begin
		if (!i_rst_n) begin
			weight_cnt   <= 0;
			weight_index <= 0;
			weight_done  <= 0;
			for (j = 0; j < 9; j = j + 1)
				weight_reg[j] <= 8'd0;
		end
		else if (is_load_weight_state) begin
			o_in_ready_r <= 1;
			if (i_in_valid) begin
				// --- ghi 4 weight / 1 chu kỳ ---
				
				weight_reg[weight_index]     <= i_in_data[31:24];
				weight_reg[weight_index + 1] <= i_in_data[23:16];
				weight_reg[weight_index + 2] <= i_in_data[15:8];
				weight_reg[weight_index + 3] <= i_in_data[7:0];
				
				// --- cập nhật chỉ số ---
				weight_index <= weight_index + 4;
				weight_cnt   <= weight_cnt + 1;

				// --- kiểm tra kết thúc ---
				if (weight_cnt == 2'd2) begin
					weight_done <= 1'b1; 
				end
			end
		end
		else begin
			weight_done <= 0;
			o_in_ready_r  <= 0;
		end
	end



	// --- combinational ---
	always @(*) begin
		col_word_cnt_next = col_word_cnt;
		row_cnt_next      = row_cnt;

		if (is_load_img_state && i_in_valid) begin	// is_load_img_state
			if (col_word_cnt == 4'd15) begin
				col_word_cnt_next = 0;
				row_cnt_next      = row_cnt + 1;
			end
			else begin
				col_word_cnt_next = col_word_cnt + 1;
			end
		end
	end

	always @(posedge i_clk or negedge i_rst_n) begin
		if (!i_rst_n) begin
			row_cnt      <= 0;
			col_word_cnt <= 0;
			for (j = 0; j < 64; j = j + 1)
				lsb_matrix[j] <= 64'd0;
		end
		else begin
			row_cnt      <= row_cnt_next;
			col_word_cnt <= col_word_cnt_next;
			if (is_load_img_state && i_in_valid)		// is_load_img_state
				lsb_matrix[row_cnt][63 - col_base -: 4] <= lsb_bits;
		end
	end

	// =============================================================
	// 8 SRAM 512x8: 2 bank × 4 SRAM song song
	// =============================================================
	reg       	sram_cen	[0:7];
	reg        	sram_wen	[0:7];
	reg [8:0]  	sram_addr 	[0:7];   // 9-bit addr (0~511)
	reg [7:0]  	sram_din 	[0:7];
	wire [7:0] 	sram_dout 	[0:7];

	genvar i;
	generate
	for (i = 0; i < 8; i = i + 1) begin : IMG_SRAM
		sram_512x8 u_sram (
		.CLK (i_clk),
		.CEN (sram_cen[i]),
		.WEN (sram_wen[i]),
		.A   (sram_addr[i]),
		.D   (sram_din[i]),
		.Q   (sram_dout[i])
		);
	end
	endgenerate

	// Sequential logic (clocked)
	always @(posedge i_clk or negedge i_rst_n) begin
		if(!i_rst_n) begin
			img_cnt  <= 12'd0;
			bank_sel <= 0;
			o_in_ready_r <= 1'b1;
			for (j=0; j<8; j=j+1) begin
				sram_cen[j] <= 1'b0;
				sram_wen[j] <= 1'b0;
				sram_din[j] <= 0;
				sram_addr [j] <= 0;
			end
		end
		else begin
			if (is_load_img_state) begin	// is_load_img_state
				o_in_ready_r <= 1'b1;   // cho phép testbench gửi data
				if (i_in_valid) begin
					bank_sel <= img_cnt[9];   // 0–511 -> bank0, 512–1023 -> bank1
					if (bank_sel == 1'b0) begin
						// ----- BANK 0 -----
						sram_cen[0] <= 1'b0; sram_wen[0] <= 1'b0;
						sram_cen[1] <= 1'b0; sram_wen[1] <= 1'b0;
						sram_cen[2] <= 1'b0; sram_wen[2] <= 1'b0;
						sram_cen[3] <= 1'b0; sram_wen[3] <= 1'b0;
						sram_cen[4] <= 1'b1; sram_wen[4] <= 1'b1;
						sram_cen[5] <= 1'b1; sram_wen[5] <= 1'b1;
						sram_cen[6] <= 1'b1; sram_wen[6] <= 1'b1;
						sram_cen[7] <= 1'b1; sram_wen[7] <= 1'b1;

						sram_addr[0] <= addr_in_bank;
						sram_addr[1] <= addr_in_bank;
						sram_addr[2] <= addr_in_bank;
						sram_addr[3] <= addr_in_bank;

						sram_din[0] <= i_in_data[31:24];
						sram_din[1] <= i_in_data[23:16];
						sram_din[2] <= i_in_data[15:8];
						sram_din[3] <= i_in_data[7:0];
					end
					else begin
						// ----- BANK 1 -----
						sram_cen[4] <= 1'b0; sram_wen[4] <= 1'b0;
						sram_cen[5] <= 1'b0; sram_wen[5] <= 1'b0;
						sram_cen[6] <= 1'b0; sram_wen[6] <= 1'b0;
						sram_cen[7] <= 1'b0; sram_wen[7] <= 1'b0;
						sram_cen[0] <= 1'b1; sram_wen[0] <= 1'b1;
						sram_cen[1] <= 1'b1; sram_wen[1] <= 1'b1;
						sram_cen[2] <= 1'b1; sram_wen[2] <= 1'b1;
						sram_cen[3] <= 1'b1; sram_wen[3] <= 1'b1;

						sram_addr[4] <= addr_in_bank;
						sram_addr[5] <= addr_in_bank;
						sram_addr[6] <= addr_in_bank;
						sram_addr[7] <= addr_in_bank;

						sram_din[4] <= i_in_data[31:24];
						sram_din[5] <= i_in_data[23:16];
						sram_din[6] <= i_in_data[15:8];
						sram_din[7] <= i_in_data[7:0];
					end

					// tăng word counter (1 word = 4 pixel)
					img_cnt <= img_cnt + 1;
				end

				// khi đã nhận đủ 1024 word = 4096 pixel
				else if (img_cnt == 12'd1024) begin
					o_in_ready_r <= 1'b0;
					bank_sel <= 0;
					for (j=0; j<8; j=j+1) begin
						sram_cen[j] <= 1'b1;
						sram_wen[j] <= 1'b1;
					end
				end
				
			end
		end
	end

	// Fixed pattern
	localparam [10:0] START_CODE = 11'b11010011100;
	localparam [12:0] STOP_CODE  = 13'b1100011101011;

	reg [5:0] row_idx;
	reg [2:0] shift_cnt;
	reg found_in_row;
	reg [56:0] ref_barcode;
	wire        start_now, stop_now, match_code;

	// ================================================================
	// FSM output logic
	// ================================================================
	// combinational detection
	wire [56:0] candidate_now;
	wire [56:0] row_segment_w;
	wire is_shift_state;
	wire is_verify_height_state;

	find_barcode u_find_barcode(
		.i_clk(i_clk),
		.i_rst_n(i_rst_n),
		.i_candidate_now(candidate_now),
		.i_row_segment_w(row_segment_w),
		.i_is_find_barcode_state(is_find_barcode_state),
		.i_match_code(match_code),

		.ref_barcode(ref_barcode),
		.shift_cnt(shift_cnt),
		.row_idx(row_idx),
		.barcode_found(barcode_found),
		.found_in_row(found_in_row),
		.is_shift_state(is_shift_state),
		.is_verify_height_state(is_verify_height_state)
	);

	assign candidate_now = (is_find_barcode_state)	// is_find_barcode_state
                        ? lsb_matrix[row_idx][63 - shift_cnt -: 57]
                        : 57'd0;

	assign start_now = (is_find_barcode_state && is_shift_state) &&
					(candidate_now[56 -: 11] == START_CODE);	// is_find_barcode_state

	assign stop_now  = (is_find_barcode_state && is_shift_state) &&
					(candidate_now[12:0]  == STOP_CODE);		// is_find_barcode_state

	assign match_code = start_now & stop_now;

	assign row_segment_w = (is_find_barcode_state && is_verify_height_state)	// is_find_barcode_state
                        ? lsb_matrix[row_idx][63 - shift_cnt -: 57]
                        : 57'd0;

	wire [7:0] kernel_size;
	wire [7:0] stride_size;
	wire [7:0] dilation_size;

	wire o_out_valid1_w, o_out_valid2_w, o_out_valid3_w;

	decode_barcode u_decode_barcode(
		.i_clk(i_clk),
		.i_rst_n(i_rst_n),
		.i_ref_barcode(ref_barcode),
		.i_is_decode_barcode_state(is_decode_barcode_state),

		.kernel_size(kernel_size),
		.stride_size(stride_size),
		.dilation_size(dilation_size),
		.o_out_valid1_r(o_out_valid1_w),
		.o_out_valid2_r(o_out_valid2_w),
		.o_out_valid3_r(o_out_valid3_w)
	);

	assign o_out_valid1 = o_out_valid1_w;
	assign o_out_valid2 = o_out_valid2_w;
	assign o_out_valid3 = o_out_valid3_w;

	assign o_out_data1 = kernel_size;
	assign o_out_data2 = stride_size;
	assign o_out_data3 = dilation_size;


endmodule
