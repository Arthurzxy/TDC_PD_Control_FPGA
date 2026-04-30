module Gate(
	input clk, // 100MHz
	input gate,
	input ava,
	input [23:0] hold_off_time,
	output wire gate_out,
	output wire latch_enable);
	
	//----------------------YC 2023.8.18-------------------------
	
	reg [31:0] k;
	reg p;
	reg n;
	wire hold;
	reg ava_sync1;
	reg ava_sync2;
	wire ava_rise;
	assign hold = ~(p^n);
	assign ava_rise = ava_sync1 & ~ava_sync2;
	
	always@(posedge clk) begin
		ava_sync1 <= ava;
		ava_sync2 <= ava_sync1;
		if(ava_rise && hold)
			p<=~p;
	end
	
	always@(posedge clk)
		if(!hold && k<hold_off_time)
			k<=k+32'd1;
		else if(!hold && k>=hold_off_time)
			n<=~n;
		else
			k<=32'd0;
			
	assign gate_out = gate & hold;
	assign latch_enable = 1'd1;
	
endmodule
