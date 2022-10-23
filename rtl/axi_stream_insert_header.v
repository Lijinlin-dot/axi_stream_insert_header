module axi_stream_insert_header #(
    parameter DATA_WD = 32,
    parameter DATA_BYTE_WD = DATA_WD / 8,
    parameter BYTE_CNT_WD = $clog2(DATA_BYTE_WD)
    ) (
    input clk,
    input rst_n,
    // AXI Stream input original data
    input valid_in,
    input [DATA_WD-1 : 0] data_in,
    input [DATA_BYTE_WD-1 : 0] keep_in,
    input last_in,
    output ready_in,
    // AXI Stream output with header inserted
    output valid_out,
    output [DATA_WD-1 : 0] data_out,
    output [DATA_BYTE_WD-1 : 0] keep_out,
    output last_out,
    input ready_out,
    // The header to be inserted to AXI Stream input
    input valid_insert,
    input [DATA_WD-1 : 0] header_insert,
    input [DATA_BYTE_WD-1 : 0] keep_insert,
    input [BYTE_CNT_WD : 0] byte_insert_cnt,
    output ready_insert
);
// Your code here
    parameter DATA_DEPTH = 32;

    `define  IDLE               3'h0      // idle state
	`define  READ_HEADER        3'h1      // read header insert data
    `define  WAIT_AXIS          3'h2      // wait valid_in and ready_in    
    `define  READ_AXIS          3'h3      // read axis stream data    
    `define  WAIT_INSERT        3'h4      // wait valid_insert is high
    `define  WRITE_NEW_AXIS     3'h5      // send axi stream data with header
    `define  TO_IDLE            3'h6      // to end, next clk to idle

    reg       [2:0]  now_state;       // State Machine register
	reg       [2:0]  next_state;      // Next State Machine value

    //store data
    reg [7:0] data_mem [0:DATA_DEPTH-1];
    reg [$clog2(DATA_DEPTH):0] front, rear;

    // output reg
    reg [DATA_WD-1 : 0]      data_out_reg;
    reg [DATA_BYTE_WD-1 : 0] keep_out_reg;

    assign ready_insert = now_state == `IDLE ? 1 : 0;
    assign ready_in     = now_state == `READ_AXIS ? 1 : 0;
    assign valid_out    = now_state == `WRITE_NEW_AXIS ? 1 : 0;
    assign last_out     = now_state == `WRITE_NEW_AXIS && front >= rear ? 1 : 0; 
    assign data_out     = data_out_reg;
    assign keep_out     = keep_out_reg;
    

    always @(*) begin
		case ( now_state )
			`IDLE           :      
                            if ( valid_insert == 1'b1 && ready_insert == 1'b1 ) next_state = `READ_AXIS;       
                            else next_state = `IDLE;			
            `READ_AXIS      :
                            if ( last_in == 1'b1 ) next_state = `WRITE_NEW_AXIS;
                            else next_state = `READ_AXIS;
            `WRITE_NEW_AXIS :
                            if ( last_out == 1'b1) next_state = `TO_IDLE;
                            else next_state = `WRITE_NEW_AXIS;
			`TO_IDLE        : next_state = `IDLE;
			 default        : next_state = `IDLE;
		endcase
	end

	always @(posedge clk or negedge rst_n) begin
		if ( rst_n == 1'b0 ) now_state <= `IDLE;
		else now_state <= next_state;        
	end

    // calculate the 1's number
    function [DATA_WD:0]swar;
        input [DATA_WD:0] data_in;
        reg [DATA_WD:0] i;
        begin
            i = data_in;
            i = (i & 32'h55555555) + ({0, i[DATA_WD:1]} & 32'h55555555);
            i = (i & 32'h33333333) + ({0, i[DATA_WD:2]} & 32'h33333333);
            i = (i & 32'h0F0F0F0F) + ({0, i[DATA_WD:4]} & 32'h0F0F0F0F);
            i = i * (32'h01010101);
            swar = i[31:24];    
        end        
    endfunction

    // data_mem initial
    genvar j;
    generate for (j = 32'd0; j < DATA_DEPTH; j=j+1) begin
        always @(posedge clk or negedge rst_n) begin
            if ( now_state == `IDLE && next_state == `IDLE )
                data_mem[j] <= 0;
            else if ( now_state == `IDLE && j >= rear && j < rear + DATA_BYTE_WD )
                data_mem[j] <= header_insert[DATA_WD - 1 - (j-rear) * 8 -: 8];
            else if ( now_state == `READ_AXIS && ready_in == 1'b1 && valid_in == 1'b1 && j >= rear && j < rear + DATA_BYTE_WD)                
                data_mem[j] <= data_in[DATA_WD - 1 -(j-rear) * 8 -: 8];
            else
                data_mem[j] <= data_mem[j];
        end
    end
    endgenerate

    // front
    always @(posedge clk or negedge rst_n) begin
		if ( now_state == `IDLE && next_state == `IDLE )
            front <= 0;
        else if ( now_state == `IDLE && next_state == `READ_AXIS )
            front <= front + DATA_BYTE_WD - byte_insert_cnt;
        else if ( now_state == `READ_AXIS && next_state != `READ_AXIS && ready_out || now_state == `WRITE_NEW_AXIS )
            front <= front + DATA_BYTE_WD;
        else 
            front <= front;
	end

    // rear
    always @(posedge clk or negedge rst_n) begin
		if (  now_state == `IDLE && next_state == `IDLE )
            rear <= 0;
        else if ( now_state == `IDLE && next_state == `READ_AXIS )
            rear <= rear + DATA_BYTE_WD;
        else if ( now_state == `READ_AXIS )            
            rear <= rear + swar(keep_in);
        else
            rear <= rear;            
	end

    
    genvar i;
    generate for (i = 32'd0; i < DATA_BYTE_WD; i=i+1) begin
        always @(posedge clk or negedge rst_n) begin
            if ( now_state == `IDLE )
                data_out_reg[DATA_WD-1-i*8 : DATA_WD-(i+1)*8] <= 0;
            else if ( next_state == `WRITE_NEW_AXIS )
                data_out_reg[DATA_WD-1-i*8 : DATA_WD-(i+1)*8] <= data_mem[front+i];       
            else
                data_out_reg[DATA_WD-1-i*8 : DATA_WD-(i+1)*8] <= data_out_reg[DATA_WD-1-i*8 : DATA_WD-(i+1)*8];       
        end
    end
    endgenerate

    generate for (i = 32'd0; i < DATA_BYTE_WD; i=i+1) begin
        always @(posedge clk or negedge rst_n) begin
            if ( now_state == `IDLE )
                keep_out_reg[i] <= 0;
            else if ( next_state == `WRITE_NEW_AXIS )
                keep_out_reg[DATA_BYTE_WD-i-1] <= front + i < rear ? 1 : 0;       
            else
                keep_out_reg[i] <= keep_out_reg[i];     
        end
    end
    endgenerate

endmodule