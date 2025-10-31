module find_barcode(
    input wire i_clk,
    input wire i_rst_n,
    input wire [56:0] i_candidate_now,
    input wire [56:0] i_row_segment_w,
    input wire i_is_find_barcode_state,
    input wire i_match_code,

    output reg [56:0] ref_barcode,
    output reg [2:0] shift_cnt,
    output reg [5:0] row_idx,
    output reg barcode_found,
    // output reg found_in_row,
    output reg is_shift_state,
    output reg is_verify_height_state

);

	// ================================================================
	// Barcode detection FSM (inside S_FIND_BARCODE)
	// ================================================================
	localparam  B_IDLE           = 3'd0;
	localparam	B_LOAD_ROW       = 3'd1;
	localparam	B_SHIFT_CHECK    = 3'd2;
	localparam	B_NEXT_ROW       = 3'd3;
	localparam	B_VERIFY_HEIGHT  = 3'd4;
	localparam	B_DONE           = 3'd5;

	reg [56:0] row_segment;
	reg [2:0] b_state, b_next;
	reg [3:0]  same_cnt;

	reg found_in_row;

    // ================================================================
	// FSM sequential
	// ================================================================
	always @(posedge i_clk or negedge i_rst_n) begin
		if (!i_rst_n)
			b_state <= B_IDLE;
		else if (i_is_find_barcode_state)		// is_find_barcode_state
			b_state <= b_next;
		else
			b_state <= B_IDLE;
	end

    // ================================================================
	// FSM next-state logic
	// ================================================================

	always @(*) begin
		is_shift_state = 0;
        is_verify_height_state = 0;
		b_next = b_state;
		case (b_state)
			B_IDLE:          b_next = B_LOAD_ROW;
			B_LOAD_ROW:      b_next = B_SHIFT_CHECK;
			B_SHIFT_CHECK: begin
                is_shift_state = 1;
				if (i_match_code)
					b_next = B_VERIFY_HEIGHT;
				else if (shift_cnt == 3'd7)
					b_next = B_NEXT_ROW;
				else
					b_next = B_SHIFT_CHECK;
			end
			B_NEXT_ROW: begin
				if (row_idx == 6'd63)
					b_next = B_DONE; // hết hàng
				else
					b_next = B_LOAD_ROW;
			end
			B_VERIFY_HEIGHT: begin
                is_verify_height_state = 1;
				if (same_cnt == 4'd10)
					b_next = B_DONE;
			end
			B_DONE: b_next = B_DONE;
			default: begin
				b_next = B_IDLE;
			end
		endcase
	end

    always @(posedge i_clk or negedge i_rst_n) begin
		if (!i_rst_n) begin
			row_idx        <= 0;
			shift_cnt      <= 0;
			found_in_row   <= 0;
			barcode_found  <= 0;
			same_cnt       <= 0;
			ref_barcode	  <= 0;
			row_segment	  <= 0;
		end
		else if (i_is_find_barcode_state) begin			// is_find_barcode_state
			case (b_state)
				B_IDLE: begin
					row_idx       <= 0;
					shift_cnt     <= 0;
					found_in_row  <= 0;
				end
				B_LOAD_ROW: begin
					shift_cnt <= 0;
				end
				B_SHIFT_CHECK: begin
					if (i_match_code && !found_in_row) begin
						found_in_row <= 1'b1;
						ref_barcode <= i_candidate_now;
					end
					else if (!found_in_row)
						shift_cnt <= shift_cnt + 1;
				end
				B_NEXT_ROW: begin
					row_idx <= row_idx + 1;
					shift_cnt <= 0;
					found_in_row <= 0;
				end
				B_VERIFY_HEIGHT: begin
					row_segment <= i_row_segment_w;

					if (row_segment == ref_barcode)
						same_cnt <= same_cnt + 1;
					else
						same_cnt <= 0; // hoặc có thể reset nếu quá sai

					if (same_cnt == 4'd9)
						barcode_found <= 1'b1;
				end
				B_DONE: begin
					barcode_found <= barcode_found;
				end
			endcase
		end
	end

endmodule