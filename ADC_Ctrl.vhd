-- Create by Jiang Xiao, QPQI, USTC, 2009-10-05

-- Serial ADC Control
-- Modified by Jiang Xiao, 2009-11-17, back-to-back readout sequence of ADC. The current readout data is the result of last convertion

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

entity ADC_Ctrl is

	port(
		clkin		: in	std_logic;	-- should be 20MHz,
		Start		: in	std_logic;  -- Once detect rising edge, data will appear at ADC[15..0] after about 5us, when clk is 20MHz
		
		SDI			: in	std_logic;
		SCLK		: buffer	std_logic:='1';
		CS			: out	std_logic:='0';
		CONVST		: out	std_logic:='1';
		SB			: out	std_logic;	--Low for straight binary, High for 2'complement
		FS			: out	std_logic;	--Should be high
		
		ADC			: out	std_logic_vector(15 downto 0)

		
	);

end entity;

architecture rtl of ADC_Ctrl is

	signal Counter : std_logic_vector(6 downto 0);
	signal CountEn : std_logic;
	signal Start_last : std_logic;
	signal Shifter : std_logic_vector(15 downto 0);
	signal ShiftEn : std_logic;

begin

	-- Generate Dout signal
	process (clkin)
	begin
		if (rising_edge(clkin)) then
			Start_last <= Start;
		end if;
	end process;	
	
	process (clkin)
	begin
		if (rising_edge(clkin)) then
			if (Start = '1' and Start_last = '0') then
				CountEn <= '1';
				Counter(6 downto 0) <= "0000000";
				Shifter(15 downto 0) <= "0000000000000000";
				ShiftEn <= '0';
			end if;
			if (CountEn = '1') then
				Counter <= Counter + 1;
				
				if (Counter(6 downto 0) = "0000000" ) then  --(=0)
					CS <= '1';
				else
					CS <= '0';
				end if;
				
				if (Counter(6 downto 0) = "0100100" ) then --(=36)
					CONVST <= '0';
				else
					CONVST <= '1';
				end if;
				
				if(Counter(6 downto 0) = "0000001") then --(=1)
					SCLK <= '1';
				end if;
				if(Counter(6 downto 0) = "0000010") then --(=2)
					ShiftEn <= '1';
					SCLK <= '0';
--					Shifter(15 downto 1) <= Shifter(14 downto 0);
--					Shifter(0) <= SDI;
				end if;
				if(ShiftEn = '1') then
					SCLK <= not SCLK;
					if(SCLK = '0' )then
						Shifter(15 downto 1) <= Shifter(14 downto 0);
						Shifter(0) <= SDI;
					end if; 
				end if;
				if (Counter = "0100001") then --(=33)
					ShiftEn <= '0';
					SCLK <= '1';
--					ADC <= Shifter;
				end if;
			else
			end if;
			if (Counter = "0101000") then --(=40)
				CountEn <= '0';
				ADC <= Shifter;
			end if;
		end if;
	end process;
	
	FS <= '1';
	SB <= '0';
	
	process (clkin)
	begin
		if (rising_edge(clkin)) then
			if(CountEn = '0')then
			end if; 
		end if;
	end process;
	

end rtl;
