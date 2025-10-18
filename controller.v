module controller(
    input wire i_clk,
    input wire i_rst_n,
    input wire i_in_valid,
    input wire i_barcode_found,
    input wire i_load_weight_done,
    input wire i_o_exe_finish,

    output reg is_load_img_state,
    output reg is_find_barcode_state,
    output reg is_decode_barcode_state,
    output reg is_load_weight_state
);


    // ================================================================
    //  State encoding
    // ================================================================
    localparam S_RESET              = 4'd0;
    localparam S_LOAD_IMG           = 4'd1;
    localparam S_FIND_BARCODE       = 4'd2;
    localparam S_DECODE_BARCODE     = 4'd3;
    localparam S_OUTPUT_CFG         = 4'd4;
    localparam S_LOAD_WEIGHT        = 4'd5;
    localparam S_CONV               = 4'd6;
    localparam S_FINISH             = 4'd7;

	reg [3:0] current_state, next_state;


    // ================================================================
    //  Next-state logic
    // ================================================================
	always @(posedge i_clk or negedge i_rst_n) begin
        if(!i_rst_n)
            current_state <= S_RESET;
        else
            current_state <= next_state;
    end

    always @(*) begin
        case(current_state)
            S_RESET:       next_state = S_LOAD_IMG;
            S_LOAD_IMG: begin
                if (!i_in_valid && !is_load_weight_state)
                    next_state = S_FIND_BARCODE;
				else
                    next_state = S_LOAD_IMG;
            end

            S_FIND_BARCODE: begin
				if (i_barcode_found) begin
					next_state = S_DECODE_BARCODE;  
				end 
				else begin
					next_state = S_FIND_BARCODE;  
				end
			end
            S_DECODE_BARCODE: begin
				// if (decode_finish)
					next_state = S_OUTPUT_CFG;
			end
            S_OUTPUT_CFG:  next_state = S_LOAD_WEIGHT;
            S_LOAD_WEIGHT:    begin
                if (is_load_weight_state && !i_in_valid && i_load_weight_done)
                    next_state = S_CONV;
                else
                    next_state = S_LOAD_WEIGHT;
            end
            S_CONV:        next_state = (i_o_exe_finish) ? S_FINISH : S_CONV;
            S_FINISH:      next_state = S_FINISH;
            default:       next_state = S_RESET;
        endcase
    end

    always @(*) begin
        is_load_img_state = 0;
        is_find_barcode_state = 0;
        is_decode_barcode_state = 0;
        is_load_weight_state = 0;
        case (current_state)
            S_LOAD_IMG: begin
                is_load_img_state = 1;
            end

            S_FIND_BARCODE: begin
                is_find_barcode_state = 1;
            end

            S_DECODE_BARCODE: begin
                is_decode_barcode_state = 1;
            end

            S_LOAD_WEIGHT: begin
                is_load_weight_state = 1;
            end
            default: is_load_img_state = 0;
        endcase
    end

endmodule