
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
	// reg bank_sel;           // chọn bank 0 hoặc 1
	wire bank_sel;           // chọn bank 0 hoặc 1
	reg [63:0] lsb_matrix [0:63]; // row-major order
	wire barcode_found;

	// wire [8:0] addr_in_bank = img_cnt[8:0]; // địa chỉ trong bank (0–511)
	wire [8:0] addr_in_bank = img_cnt[8:0]; // địa chỉ trong bank (0–511)
	wire is_load_img_state, is_find_barcode_state, is_decode_barcode_state, is_load_weight_state, is_conv_state;
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
		// .i_o_exe_finish(o_exe_finish),

		.is_load_img_state(is_load_img_state),
		.is_find_barcode_state(is_find_barcode_state),
		.is_decode_barcode_state(is_decode_barcode_state),
		.is_load_weight_state(is_load_weight_state),
		.is_conv_state(is_conv_state)
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
		else begin
			if (is_load_weight_state) begin
				// o_in_ready_r <= 1;
				if (i_in_valid) begin
					case (weight_index)
						4'd0: begin
							weight_reg[0] <= $signed(i_in_data[31:24]);
							weight_reg[1] <= $signed(i_in_data[23:16]);
							weight_reg[2] <= $signed(i_in_data[15:8]);
							weight_reg[3] <= $signed(i_in_data[7:0]);
						end
						4'd4: begin
							weight_reg[4] <= $signed(i_in_data[31:24]);
							weight_reg[5] <= $signed(i_in_data[23:16]);
							weight_reg[6] <= $signed(i_in_data[15:8]);
							weight_reg[7] <= $signed(i_in_data[7:0]);
						end
						4'd8: begin
							// chỉ ghi phần tử cuối
							weight_reg[8] <= $signed(i_in_data[31:24]);
						end
					endcase

					// cập nhật index và counter
					if (weight_index < 8)
						weight_index <= weight_index + 4;
					weight_cnt <= weight_cnt + 1;

					// đánh dấu hoàn tất
					if (weight_cnt == 2'd2)
						weight_done <= 1'b1;
					else
						weight_done <= 1'b0;
				end
			end
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

	assign bank_sel = img_cnt[9]; 

	always @(posedge i_clk or negedge i_rst_n) begin
		if (!i_rst_n)
			o_in_ready_r <= 1'b0;
		else if (is_load_img_state)
			o_in_ready_r <= 1'b1;
		else if (is_load_weight_state && (img_cnt == 12'd1024))
			o_in_ready_r <= 1'b1;
		else
			o_in_ready_r <= 1'b0;
	end
	

	// Sequential logic (clocked)
	always @(posedge i_clk or negedge i_rst_n) begin
		if(!i_rst_n) begin
			img_cnt  <= 12'd0;
		end
		else begin
			if (is_load_img_state) begin	// is_load_img_state
				// o_in_ready_r <= 1'b1;   // cho phép testbench gửi data
				if (i_in_valid) begin
					img_cnt <= img_cnt + 1;
				end
				else 
					img_cnt <= img_cnt;
			end
		end
	end

	// Fixed pattern
	localparam [10:0] START_CODE = 11'b11010011100;
	localparam [12:0] STOP_CODE  = 13'b1100011101011;

	wire [5:0] row_idx;
	wire [2:0] shift_cnt;
	// wire found_in_row;
	wire [56:0] ref_barcode;
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
		// .found_in_row(found_in_row),
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

	reg is_decode_barcode_state_d1, is_decode_barcode_state_d2;
	
	always @(posedge i_clk or negedge i_rst_n) begin
		if (!i_rst_n) begin
			is_decode_barcode_state_d1 <= 0;
			is_decode_barcode_state_d2 <= 0;
		end else begin
			is_decode_barcode_state_d1 <= is_decode_barcode_state;
			is_decode_barcode_state_d2 <= is_decode_barcode_state_d1;
		end
	end

	reg [1:0] stride_r, dilation_r;
	always @(posedge i_clk or negedge i_rst_n)
		if (!i_rst_n) begin
			stride_r   <= 0;
			dilation_r <= 0;
		end else begin
			if (is_decode_barcode_state_d1) begin
				stride_r   <= stride_size[1:0];
				dilation_r <= dilation_size[1:0];
			end
	end

	// ================================================================
	// FSM con điều khiển LOAD line (có padding = 1)
	// ================================================================

	localparam CL_IDLE  	= 2'd0;
	localparam CL_READ  	= 2'd1;
	localparam CL_COMPUTE 	= 2'd2;
	// localparam CL_HOLD3 	= 2'd3;

	reg [1:0] cur_state, next_state;
	
	reg [7:0] linebuf0 [0:63];
	reg [7:0] linebuf1 [0:63];
	reg [7:0] linebuf2 [0:63];
	reg [7:0] linebuf3 [0:63];
	reg [7:0] linebuf4 [0:63];

	reg [7:0] lineload [0:63];
	reg conv_done;
	// reg conv_valid_d1, conv_valid_d2, conv_valid_d3, conv_valid_d4;
	reg [3:0] conv_col_word_idx_r [0:3];
	reg [6:0] conv_row_idx;
	reg [3:0] conv_col_word_idx;
	reg warmup_done;  // flag báo đã đủ 3 dòng để compute
	reg line_ready;

	wire [8:0] conv_addr = conv_row_idx * 16 + conv_col_word_idx;

	// CHỈ CẦN 2 dòng ảnh + 1 dòng pad 0 ở trên cùng
	reg [2:0] lines_filled;  

	// ghi pixel hợp lệ
	// wire write_ena  = is_conv_state & conv_valid_d4;
	wire write_ena;

	wire [5:0] wpos = write_ena ? {conv_col_word_idx_r[2], 2'b00} : 0;
	
	// wire write_last = write_ena & (conv_col_word_idx_r[2] == 4'd15);

	reg read_active_d1, read_active_d2;

	always @(posedge i_clk or negedge i_rst_n) begin
		if (!i_rst_n) begin
			read_active_d1 <= 0;
			read_active_d2 <= 0;
		end else begin
			read_active_d1 <= (cur_state == CL_READ);
			read_active_d2 <= read_active_d1;
		end
	end

	assign write_ena = read_active_d2;


	integer k;
	always @(posedge i_clk or negedge i_rst_n) begin
		if (!i_rst_n) begin
			for (k=0; k<4; k=k+1)
				conv_col_word_idx_r[k] <= 0;
		end else if (cur_state == CL_COMPUTE) begin
			// ❄ Freeze: giữ nguyên khi compute
			for (k=0; k<4; k=k+1)
				conv_col_word_idx_r[k] <= conv_col_word_idx_r[k];
		end else begin
			// 🔄 Resume khi read
			conv_col_word_idx_r[0] <= conv_col_word_idx;
			conv_col_word_idx_r[1] <= conv_col_word_idx_r[0];
			conv_col_word_idx_r[2] <= conv_col_word_idx_r[1];
			conv_col_word_idx_r[3] <= conv_col_word_idx_r[2];
		end
	end

	reg [7:0] sram_dout_r [0:7];
	generate
		for (i=0; i<8; i=i+1) begin : SRAM_OUT_PIPE
			always @(posedge i_clk or negedge i_rst_n) begin
				if (!i_rst_n)
					sram_dout_r[i] <= 0;
				else begin
					sram_dout_r[i] <= sram_dout[i];
				end
			end
		end
	endgenerate
	// ================================================================
	// State register
	// ================================================================
	always @(posedge i_clk or negedge i_rst_n)
		if (!i_rst_n)
			cur_state <= CL_IDLE;
		else
			cur_state <= next_state;

	// ================================================================
	// Next-state logic
	// ================================================================

	reg [1:0] line_loaded; // đếm số dòng đã load (0, 1, 2)
	reg after_warmup;           // flag báo đã qua phase warm-up
	wire [1:0] pad_rows = (dilation_r == 2'd2) ? 2'd2 : 2'd1;

	
	wire [1:0] bank_sel_read = 
			(conv_row_idx >= 7'd64) ? 2'd2 :    // dòng pad cuối
			(conv_row_idx >= 7'd32) ? 2'd1 :    // bank1 (33–64)
									2'd0 ;   // bank0 (1–32)


	// ================================================================
	// Unified SRAM Control Logic (no for loop, Spyglass-clean)
	// ================================================================
	always @(posedge i_clk or negedge i_rst_n) begin
		if (!i_rst_n) begin
			// Reset tất cả SRAM
			sram_cen[0]  <= 1'b1; sram_cen[1]  <= 1'b1; sram_cen[2]  <= 1'b1; sram_cen[3]  <= 1'b1;
			sram_cen[4]  <= 1'b1; sram_cen[5]  <= 1'b1; sram_cen[6]  <= 1'b1; sram_cen[7]  <= 1'b1;

			sram_wen[0]  <= 1'b1; sram_wen[1]  <= 1'b1; sram_wen[2]  <= 1'b1; sram_wen[3]  <= 1'b1;
			sram_wen[4]  <= 1'b1; sram_wen[5]  <= 1'b1; sram_wen[6]  <= 1'b1; sram_wen[7]  <= 1'b1;

			sram_addr[0] <= 9'd0; sram_addr[1] <= 9'd0; sram_addr[2] <= 9'd0; sram_addr[3] <= 9'd0;
			sram_addr[4] <= 9'd0; sram_addr[5] <= 9'd0; sram_addr[6] <= 9'd0; sram_addr[7] <= 9'd0;

			sram_din[0]  <= 8'd0; sram_din[1]  <= 8'd0; sram_din[2]  <= 8'd0; sram_din[3]  <= 8'd0;
			sram_din[4]  <= 8'd0; sram_din[5]  <= 8'd0; sram_din[6]  <= 8'd0; sram_din[7]  <= 8'd0;
		end 
		else begin
			// Default disable tất cả
			sram_cen[0] <= 1'b1; sram_cen[1] <= 1'b1; sram_cen[2] <= 1'b1; sram_cen[3] <= 1'b1;
			sram_cen[4] <= 1'b1; sram_cen[5] <= 1'b1; sram_cen[6] <= 1'b1; sram_cen[7] <= 1'b1;

			sram_wen[0] <= 1'b1; sram_wen[1] <= 1'b1; sram_wen[2] <= 1'b1; sram_wen[3] <= 1'b1;
			sram_wen[4] <= 1'b1; sram_wen[5] <= 1'b1; sram_wen[6] <= 1'b1; sram_wen[7] <= 1'b1;

			// =====================================================
			// CASE 1: LOAD IMAGE
			// =====================================================
			if (is_load_img_state && i_in_valid) begin
				if (bank_sel == 1'b0) begin
					// ---- BANK 0 ----
					sram_cen[0] <= 1'b0; sram_wen[0] <= 1'b0; sram_addr[0] <= addr_in_bank; sram_din[0] <= i_in_data[31:24];
					sram_cen[1] <= 1'b0; sram_wen[1] <= 1'b0; sram_addr[1] <= addr_in_bank; sram_din[1] <= i_in_data[23:16];
					sram_cen[2] <= 1'b0; sram_wen[2] <= 1'b0; sram_addr[2] <= addr_in_bank; sram_din[2] <= i_in_data[15:8];
					sram_cen[3] <= 1'b0; sram_wen[3] <= 1'b0; sram_addr[3] <= addr_in_bank; sram_din[3] <= i_in_data[7:0];
					// disable bank1
					sram_cen[4] <= 1'b1; sram_cen[5] <= 1'b1; sram_cen[6] <= 1'b1; sram_cen[7] <= 1'b1;
					sram_wen[4] <= 1'b1; sram_wen[5] <= 1'b1; sram_wen[6] <= 1'b1; sram_wen[7] <= 1'b1;
				end 
				else begin
					// ---- BANK 1 ----
					sram_cen[4] <= 1'b0; sram_wen[4] <= 1'b0; sram_addr[4] <= addr_in_bank; sram_din[4] <= i_in_data[31:24];
					sram_cen[5] <= 1'b0; sram_wen[5] <= 1'b0; sram_addr[5] <= addr_in_bank; sram_din[5] <= i_in_data[23:16];
					sram_cen[6] <= 1'b0; sram_wen[6] <= 1'b0; sram_addr[6] <= addr_in_bank; sram_din[6] <= i_in_data[15:8];
					sram_cen[7] <= 1'b0; sram_wen[7] <= 1'b0; sram_addr[7] <= addr_in_bank; sram_din[7] <= i_in_data[7:0];
					// disable bank0
					sram_cen[0] <= 1'b1; sram_cen[1] <= 1'b1; sram_cen[2] <= 1'b1; sram_cen[3] <= 1'b1;
					sram_wen[0] <= 1'b1; sram_wen[1] <= 1'b1; sram_wen[2] <= 1'b1; sram_wen[3] <= 1'b1;
				end
			end 

			// =====================================================
			// CASE 2: CONVOLUTION READ (CL_READ)
			// =====================================================
			else if ((cur_state == CL_READ)) begin
				case (bank_sel_read)
					// ---- BANK 0 ----
					2'd0: begin
						sram_cen[0] <= 1'b0; sram_wen[0] <= 1'b1; sram_addr[0] <= conv_addr;
						sram_cen[1] <= 1'b0; sram_wen[1] <= 1'b1; sram_addr[1] <= conv_addr;
						sram_cen[2] <= 1'b0; sram_wen[2] <= 1'b1; sram_addr[2] <= conv_addr;
						sram_cen[3] <= 1'b0; sram_wen[3] <= 1'b1; sram_addr[3] <= conv_addr;
						sram_cen[4] <= 1'b1; sram_cen[5] <= 1'b1; sram_cen[6] <= 1'b1; sram_cen[7] <= 1'b1;
						sram_wen[4] <= 1'b1; sram_wen[5] <= 1'b1; sram_wen[6] <= 1'b1; sram_wen[7] <= 1'b1;
					end

					// ---- BANK 1 ----
					2'd1: begin
						sram_cen[4] <= 1'b0; sram_wen[4] <= 1'b1; sram_addr[4] <= conv_addr;
						sram_cen[5] <= 1'b0; sram_wen[5] <= 1'b1; sram_addr[5] <= conv_addr;
						sram_cen[6] <= 1'b0; sram_wen[6] <= 1'b1; sram_addr[6] <= conv_addr;
						sram_cen[7] <= 1'b0; sram_wen[7] <= 1'b1; sram_addr[7] <= conv_addr;
						sram_cen[0] <= 1'b1; sram_cen[1] <= 1'b1; sram_cen[2] <= 1'b1; sram_cen[3] <= 1'b1;
						sram_wen[0] <= 1'b1; sram_wen[1] <= 1'b1; sram_wen[2] <= 1'b1; sram_wen[3] <= 1'b1;
					end

					// ---- PAD LINE ----
					2'd2: begin
						sram_cen[0] <= 1'b1; sram_cen[1] <= 1'b1; sram_cen[2] <= 1'b1; sram_cen[3] <= 1'b1;
						sram_cen[4] <= 1'b1; sram_cen[5] <= 1'b1; sram_cen[6] <= 1'b1; sram_cen[7] <= 1'b1;
						sram_wen[0] <= 1'b1; sram_wen[1] <= 1'b1; sram_wen[2] <= 1'b1; sram_wen[3] <= 1'b1;
						sram_wen[4] <= 1'b1; sram_wen[5] <= 1'b1; sram_wen[6] <= 1'b1; sram_wen[7] <= 1'b1;
						sram_addr[0] <= 9'd0; sram_addr[1] <= 9'd0; sram_addr[2] <= 9'd0; sram_addr[3] <= 9'd0;
						sram_addr[4] <= 9'd0; sram_addr[5] <= 9'd0; sram_addr[6] <= 9'd0; sram_addr[7] <= 9'd0;
					end
				endcase
			end 

			// =====================================================
			// CASE 3: OTHER STATES
			// =====================================================
			else begin
				// disable tất cả SRAM
				sram_cen[0] <= 1'b1; sram_cen[1] <= 1'b1; sram_cen[2] <= 1'b1; sram_cen[3] <= 1'b1;
				sram_cen[4] <= 1'b1; sram_cen[5] <= 1'b1; sram_cen[6] <= 1'b1; sram_cen[7] <= 1'b1;
				sram_wen[0] <= 1'b1; sram_wen[1] <= 1'b1; sram_wen[2] <= 1'b1; sram_wen[3] <= 1'b1;
				sram_wen[4] <= 1'b1; sram_wen[5] <= 1'b1; sram_wen[6] <= 1'b1; sram_wen[7] <= 1'b1;
			end
		end
	end


	
	always @(*) begin
		next_state = cur_state;
		case (cur_state)
			CL_IDLE: begin
				if (is_conv_state)
					next_state = CL_READ;
			end

			// ---- chỉ chuyển sang COMPUTE khi warmup_done = 1 ----
			CL_READ: begin
				if (warmup_done && line_ready)
					next_state = CL_COMPUTE;
			end

			// ---- tính toán khi đủ 3 dòng ----
			CL_COMPUTE: begin
				if (conv_done) begin
					if (conv_row_idx < 7'd65 + pad_rows - stride_r)
						next_state = CL_READ;   // load dòng kế tiếp
					else
						next_state = CL_IDLE;  // hết ảnh
				end
			end

		endcase
	end
	
	// ================================================================
	// Output logic + datapath
	// ================================================================
	reg [6:0] conv_col_idx;
	reg [7:0] conv_out;
	reg compute_enable;

	// cửa sổ 3x3 trượt theo cột
	reg signed [7:0] w00, w01, w02;
	reg signed [7:0] w10, w11, w12;
	reg signed [7:0] w20, w21, w22;
	reg signed [19:0] acc;

	wire [6:0] dil_off = (dilation_r == 2'd2) ? 7'd2 : 7'd1;

	// Chọn 3 dòng tương ứng theo dilation (vertical)
	reg [7:0] line_top [0:63];
	reg [7:0] line_mid [0:63];
	reg [7:0] line_bot [0:63];

	always @(*) begin
		for (j = 0; j < 64; j = j + 1) begin
			case (dilation_r)
				2'd1: begin
					line_top[j] = linebuf0[j];
					line_mid[j] = linebuf1[j];
					line_bot[j] = linebuf2[j];
				end
				2'd2: begin
					line_top[j] = linebuf0[j];
					line_mid[j] = linebuf2[j];
					line_bot[j] = linebuf4[j];
				end
				default: begin
					line_top[j] = linebuf0[j];
					line_mid[j] = linebuf1[j];
					line_bot[j] = linebuf2[j];
				end
			endcase
		end
	end

	reg [5:0] wpos0, wpos1, wpos2, wpos3;
	always @(*) begin
		wpos0 = wpos;
		wpos1 = wpos + 1;
		wpos2 = wpos + 2;
		wpos3 = wpos + 3;
	end

	wire [5:0] col_left  = (conv_col_idx >= dil_off) ? (conv_col_idx - dil_off) : 6'd0;
	wire [5:0] col_right = (conv_col_idx + dil_off > 63) ? 6'd63 : (conv_col_idx + dil_off);

	always @(posedge i_clk or negedge i_rst_n) begin
		if (!i_rst_n) begin
			conv_row_idx      <= 0;
			conv_col_word_idx <= 0;
			lines_filled      <= 2'd1;   // ❗️coi pad trên cùng là 1 dòng đã sẵn
			conv_done         <= 0;
			conv_col_idx      <= 0;
			compute_enable    <= 0;
			warmup_done       <= 0;
			after_warmup 	  <= 1'b0;
			line_loaded  	  <= 0;
			line_ready 		  <= 0;
			w00 			  <= 0;
			w01 			  <= 0;
			w02 			  <= 0;
			w10 			  <= 0;
			w11 			  <= 0;
			w12 			  <= 0;
			w20 			  <= 0;
			w21 			  <= 0;
			w22 			  <= 0;
			acc				  <= 0;

			for (j=0; j<64; j=j+1) begin
				linebuf0[j] <= 0;
				linebuf1[j] <= 0;
				linebuf2[j] <= 0;
				linebuf3[j] <= 0;
				linebuf4[j] <= 0;
				lineload[j] <= 0;
			end
		end else begin
			case (cur_state)
				// --------------------------------------------------------
				// IDLE
				// --------------------------------------------------------
				CL_IDLE: begin
					compute_enable <= 0;
					warmup_done    <= 0;
				end

				// --------------------------------------------------------
				// READ: load dòng ảnh và shift buffer khi đủ 1 dòng
				// --------------------------------------------------------
				CL_READ: begin
					case (bank_sel_read)
						2'd0: begin
							if (write_ena) begin
								lineload[wpos0] <= sram_dout_r[0];
								lineload[wpos1] <= sram_dout_r[1];
								lineload[wpos2] <= sram_dout_r[2];
								lineload[wpos3] <= sram_dout_r[3];
							end
						end

						2'd1: begin
							if (write_ena) begin
								lineload[wpos0] <= sram_dout_r[4];
								lineload[wpos1] <= sram_dout_r[5];
								lineload[wpos2] <= sram_dout_r[6];
								lineload[wpos3] <= sram_dout_r[7];
							end
						end

						2'd2: begin
							// ghi toàn 0 vào lineload
							if (write_ena) begin
								lineload[wpos0] <= 8'd0;
								lineload[wpos1] <= 8'd0;
								lineload[wpos2] <= 8'd0;
								lineload[wpos3] <= 8'd0;
							end
						end
					endcase

					// tăng chỉ số đọc SRAM
					if (conv_col_word_idx_r[3] == 4'd15) begin
						conv_col_word_idx <= 0;
						if (conv_row_idx == (7'd64 + pad_rows))
							conv_row_idx <= 0;
						else
							conv_row_idx <= conv_row_idx + 1;
					end else begin
						conv_col_word_idx <= conv_col_word_idx + 1;
					end

					// khi đọc xong 1 dòng → shift line buffer
					if (conv_col_word_idx_r[3] == 4'd15) begin
						// shift buffer
						if (dilation_r == 2'd1) begin
							for (j=0; j<64; j=j+1) begin
								linebuf0[j] <= linebuf1[j];
								linebuf1[j] <= linebuf2[j];
								linebuf2[j] <= lineload[j];
							end
						end else if (dilation_r == 2'd2) begin
							for (j=0; j<64; j=j+1) begin
								linebuf0[j] <= linebuf1[j];
								linebuf1[j] <= linebuf2[j];
								linebuf2[j] <= linebuf3[j];
								linebuf3[j] <= linebuf4[j];
								linebuf4[j] <= lineload[j];
							end
						end
						// ----------- WARM-UP PHASE -----------
						if (!after_warmup) begin
							line_ready <= 1'b1;
							if (dilation_r == 2'd1) begin
								if (lines_filled < 3)
									lines_filled <= lines_filled + 1'b1;
								if (lines_filled == 2) begin
									warmup_done <= 1'b1;
									compute_enable <= 1;
								end
							end
							else if (dilation_r == 2'd2) begin
								if (lines_filled < 5)
									lines_filled <= lines_filled + 1'b1;
								if (lines_filled == 3) begin
									warmup_done <= 1'b1;
									compute_enable <= 1;
								end
							end
						end

						// ----------- STEADY-STATE PHASE -----------
						else begin
							if (line_loaded < stride_r)
								line_loaded <= line_loaded + 1'b1;

							// Khi đủ stride_r dòng mới set line_ready
							if (line_loaded == stride_r - 1)
								line_ready <= 1'b1;
							else
								line_ready <= 1'b0;
						end
					end
					else begin
						line_ready <= 1'b0;
					end
				end

				// --------------------------------------------------------
				// COMPUTE: thực hiện conv3x3 khi đã đủ 3 dòng
				// --------------------------------------------------------
				CL_COMPUTE: begin
					// clear flag warmup khi vào compute
					line_ready <= 1'b0;
					line_loaded <= 0;
					after_warmup <= 1'b1;

					if (compute_enable) begin

						w00 <= (conv_col_idx < dil_off) ? 16'sd0 : $signed({8'd0, line_top[col_left]});
						w01 <= $signed({8'd0, line_top[conv_col_idx[5:0]]});
						w02 <= (conv_col_idx >= (64 - dil_off)) ? 16'sd0 : $signed({8'd0, line_top[col_right]});

						w10 <= (conv_col_idx < dil_off) ? 16'sd0 : $signed({8'd0, line_mid[col_left]});
						w11 <= $signed({8'd0, line_mid[conv_col_idx[5:0]]});
						w12 <= (conv_col_idx >= (64 - dil_off)) ? 16'sd0 : $signed({8'd0, line_mid[col_right]});

						w20 <= (conv_col_idx < dil_off) ? 16'sd0 : $signed({8'd0, line_bot[col_left]});
						w21 <= $signed({8'd0, line_bot[conv_col_idx[5:0]]});
						w22 <= (conv_col_idx >= (64 - dil_off)) ? 16'sd0 : $signed({8'd0, line_bot[col_right]});


						// =========================================================
						// STEP 2: Multiply–Accumulate, giữ nguyên full precision (Q9.7)
						// =========================================================
						// weight_reg là Q1.7 signed
						// pixel là Q8.0 unsigned → Q9.7 signed sau nhân
						acc <= ($signed({1'b0, w00}) * (weight_reg[0])) +
							($signed({1'b0, w01}) * (weight_reg[1])) +
							($signed({1'b0, w02}) * (weight_reg[2])) +
							($signed({1'b0, w10}) * (weight_reg[3])) +
							($signed({1'b0, w11}) * (weight_reg[4])) +
							($signed({1'b0, w12}) * (weight_reg[5])) +
							($signed({1'b0, w20}) * (weight_reg[6])) +
							($signed({1'b0, w21}) * (weight_reg[7])) +
							($signed({1'b0, w22}) * (weight_reg[8]));
						// ---- reset đầu dòng mới ----
						if (conv_done) begin
							conv_col_idx <= 0;   // reset counter
							conv_done    <= 0;   // clear flag sau 1 chu kỳ
						end
						else begin
							// ---- tăng cột ----
							if (conv_col_idx == (7'd64 - stride_r)) begin
								conv_col_idx <= 0;
								conv_done    <= 1;
							end else begin
								conv_col_idx <= conv_col_idx + stride_r;
								conv_done    <= 0;
							end
						end
					end
				end
			endcase
		end
	end

	wire signed [19:0] acc_rounded = acc + 20'sd64;  
	wire signed [12:0] acc_int = acc_rounded[19:7];
	always @(*) begin
	if (acc_int > 255)
		conv_out = 8'd255;
	else if (acc_int < 0)
		conv_out = 8'd0;
	else
		conv_out = acc_int[7:0];
	end

	reg [7:0]  conv_out_buf [0:3];  // gom 4 pixel
	reg [1:0]  out_pixel_cnt;       // đếm 0..3 trong nhóm 4
	reg [11:0] out_addr_base;       // địa chỉ nhóm hiện tại (0..4095)

	reg [7:0]  o_out_data1_r;
	reg [7:0]  o_out_data2_r;
	reg [7:0]  o_out_data3_r;
	reg [7:0]  o_out_data4_r;

	reg [11:0]  o_out_addr1_r;
	reg [11:0]  o_out_addr2_r;
	reg [11:0]  o_out_addr3_r;
	reg [11:0]  o_out_addr4_r;

	reg o_out_valid1_r, o_out_valid2_r, o_out_valid3_r, o_out_valid4_r;

	reg o_exe_finish_r;

	localparam [12:0] NUM_OUTPUT = 13'd4092;   // đủ để chứa 4096

	reg [12:0] num_output_total;

	always @(posedge i_clk or negedge i_rst_n) begin
		if (!i_rst_n)
			num_output_total <= 13'd0;
		else if (is_decode_barcode_state_d2)
			num_output_total <= (stride_r == 2'd1) ? 13'd4092 : 13'd1020;
	end
	
	reg compute_active_d1, compute_active_d2;
	reg conv_done_d1, conv_done_d2, conv_done_d3;
	wire compute_active = compute_active_d2; 


	//-----------------------------------------------------
// OUTPUT LOGIC — CHỈ HOẠT ĐỘNG TRONG COMPUTE
//-----------------------------------------------------

wire out_pixel_cnt_ok = out_pixel_cnt == 2'd3 ? 1 : 0;
always @(posedge i_clk or negedge i_rst_n) begin
	if (!i_rst_n) begin
		out_pixel_cnt  <= 0;
		out_addr_base  <= 0;

		o_out_data1_r <= 0;
		o_out_data2_r <= 0;
		o_out_data3_r <= 0;
		o_out_data4_r <= 0;

		o_out_valid1_r <= 0;
		o_out_valid2_r <= 0;
		o_out_valid3_r <= 0;
		o_out_valid4_r <= 0;

		o_out_addr1_r <= 0;
		o_out_addr2_r <= 0;
		o_out_addr3_r <= 0;
		o_out_addr4_r <= 0;

		conv_out_buf[0] <= 0;
		conv_out_buf[1] <= 0;
		conv_out_buf[2] <= 0;
		conv_out_buf[3] <= 0;
	end
	else if (compute_active) begin
		// chỉ update khi chưa conv_done
		if (!conv_done_d2) begin
			conv_out_buf[out_pixel_cnt] <= conv_out;

			// nếu chưa đủ 4 pixel thì tiếp tục tăng
			if (out_pixel_cnt_ok) begin
				// phát nhóm 4 pixel
				o_out_data1_r <= conv_out_buf[0];
				o_out_data2_r <= conv_out_buf[1];
				o_out_data3_r <= conv_out_buf[2];
				o_out_data4_r <= conv_out;

				o_out_valid1_r <= 1'b1;
				o_out_valid2_r <= 1'b1;
				o_out_valid3_r <= 1'b1;
				o_out_valid4_r <= 1'b1;

				o_out_addr1_r <= out_addr_base + 12'd0;
				o_out_addr2_r <= out_addr_base + 12'd1;
				o_out_addr3_r <= out_addr_base + 12'd2;
				o_out_addr4_r <= out_addr_base + 12'd3;

				out_addr_base <= out_addr_base + 12'd4;
				out_pixel_cnt <= 0;
			end
			else begin
				out_pixel_cnt <= out_pixel_cnt + 1;

				o_out_valid1_r <= 1'b0;
				o_out_valid2_r <= 1'b0;
				o_out_valid3_r <= 1'b0;
				o_out_valid4_r <= 1'b0;
			end
		end 
		else begin
			// Khi conv_done → giữ nguyên, không tăng nữa
			out_pixel_cnt <= out_pixel_cnt;
			o_out_valid1_r <= 0;
			o_out_valid2_r <= 0;
			o_out_valid3_r <= 0;
			o_out_valid4_r <= 0;
		end

	end
	else begin
		// ngoài compute thì clear
		out_pixel_cnt  <= 0;
		o_out_valid1_r <= 0;
		o_out_valid2_r <= 0;
		o_out_valid3_r <= 0;
		o_out_valid4_r <= 0;
	end
end


	always @(posedge i_clk or negedge i_rst_n) begin
		if (!i_rst_n) begin
			compute_active_d1 	<= 0;
			o_exe_finish_r 		<= 0;
			compute_active_d2 	<= 0;
			conv_done_d1		<= 0;
			conv_done_d2		<= 0;
		end else begin
			compute_active_d1 <= (cur_state == CL_COMPUTE) && compute_enable;
			compute_active_d2 <= compute_active_d1;
			conv_done_d1 <= conv_done;
			conv_done_d2 <= conv_done_d1;
			o_exe_finish_r <=  ((o_out_addr4_r == num_output_total + 3) ||
                            (is_decode_barcode_state_d1 &&
							((kernel_size   == 8'd0) &&
							(stride_size   == 8'd0) &&
							(dilation_size == 8'd0))))
							? 1'b1 : 1'b0;
		end
	end

	assign o_out_data1 = is_decode_barcode_state_d1 ? kernel_size  : o_out_data1_r;
	assign o_out_data2 = is_decode_barcode_state_d1 ? stride_size  : o_out_data2_r;
	assign o_out_data3 = is_decode_barcode_state_d1 ? dilation_size: o_out_data3_r;
	assign o_out_data4 = o_out_data4_r;

	assign o_out_valid1 = is_decode_barcode_state_d1 ? o_out_valid1_w : o_out_valid1_r;
	assign o_out_valid2 = is_decode_barcode_state_d1 ? o_out_valid2_w : o_out_valid2_r;
	assign o_out_valid3 = is_decode_barcode_state_d1 ? o_out_valid3_w : o_out_valid3_r;
	assign o_out_valid4 = o_out_valid4_r;

	assign o_out_addr1 = o_out_addr1_r;
	assign o_out_addr2 = o_out_addr2_r;
	assign o_out_addr3 = o_out_addr3_r;
	assign o_out_addr4 = o_out_addr4_r;

	assign o_exe_finish = o_exe_finish_r;


endmodule
