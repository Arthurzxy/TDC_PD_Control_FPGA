module M95512(
	clk,
	r_start,
	w_start,
	w_data,
	rom_q,
	address,
	
	rom_c,
	rom_d,
	rom_s,
	rom_w,
	rom_h,
	r_data,
	r_done,
	busy);
	
	//----------------YC 2021.8.19------------------- read or write a page of M95512
	// read delay around 65 us
	
	input clk;
	input r_start;
	input w_start;
	input [1023:0] w_data;
	input rom_q;
	input [15:0] address;
	
	output wire rom_c;
	output reg rom_d;
	output reg rom_s;
	output wire rom_w;
	output wire rom_h;
	output reg [1023:0] r_data;
	output reg r_done;
	output wire busy;
	
	assign rom_w=1'd1;
	assign rom_h=1'd1;
	
	reg rom_clk_en;
	assign rom_c=rom_clk_en ? clk : 1'd1;
	
	reg w_busy;
	reg r_busy;
	assign busy=w_busy|r_busy;
	
	reg [1057:0] w_data_reg;
	reg [23:0] r_data_reg;
	reg q;
	reg [15:0] k;
	always@(posedge clk)
		if(w_start & (!busy))
			begin
				rom_clk_en<=1'd0;
				rom_s<=1'd1;
				//w_data_reg<={8'b00000010,address,w_data};
				k<=16'd0;
				w_busy<=1'd1;
			end
		else if(w_busy)
			case(k)
			0: 
				begin
					rom_clk_en<=1'd1;
					rom_s<=1'd0;
					k<=k+16'd1;
				end
			8:
				begin
					rom_clk_en<=1'd0;
					rom_s<=1'd0;
					k<=k+16'd1;
				end
			9:
				begin
					rom_clk_en<=1'd0;
					rom_s<=1'd1;
					k<=k+16'd1;
				end
			10:
				begin
					rom_clk_en<=1'd1;
					rom_s<=1'd0;
					k<=k+16'd1;
				end
			1058: 
				begin
					rom_clk_en<=1'd0;
					rom_s<=1'd0;
					w_busy<=1'd1;
					k<=k+16'd1;
				end
			1059:
				begin
					rom_clk_en<=1'd0;
					rom_s<=1'd1;
					w_busy<=1'd0;
				end
			default:
				begin
					rom_s<=1'd0;
					k<=k+16'd1;
				end
			endcase
		else if(r_start & (!busy))
			begin
				rom_clk_en<=1'd0;
				rom_s<=1'd1;
				//r_data_reg<={8'b00000011,address};
				k<=16'd0;
				r_busy<=1'd1;
			end
		else if(r_busy)
			case(k)
			0: 
				begin
					rom_clk_en<=1'd1;
					rom_s<=1'd0;
					k<=k+16'd1;
				end
			1048: 
				begin
					rom_clk_en<=1'd0;
					rom_s<=1'd0;
					q<=rom_q;
					k<=k+16'd1;
				end
			1049:
				begin
					rom_clk_en<=1'd0;
					rom_s<=1'd1;
					r_busy<=1'd0;
					r_done<=1'd1;
				end
			default:
				begin
					rom_s<=1'd0;
					k<=k+16'd1;
					q<=rom_q;
				end
			endcase
		else
			begin
				rom_clk_en<=1'd0;
				rom_s<=1'd1;
				k<=16'd0;
				w_busy<=1'd0;
				r_busy<=1'd0;
				r_done<=1'd0;
			end
				
	always@(negedge clk)
		if(w_busy)
			case(k)
			0: w_data_reg<={8'b00000110,2'b00,8'b00000010,address,w_data};
			default:
				begin
					rom_d<=w_data_reg[1057];
					w_data_reg<=w_data_reg<<1;
				end
			endcase
		else if(r_busy)
			case(k)
			0: r_data_reg<={8'b00000011,address};
			default:
				begin
					rom_d<=r_data_reg[23];
					r_data_reg<=r_data_reg<<1;
				end
			endcase
			
	always@(negedge clk)
		if(r_busy && k>16'd25)
			begin
				r_data[0]<=q;
				r_data[1023:1]<=r_data[1022:0];
			end
			
endmodule

