// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
// -------------------------------------------------------------------------------

`timescale 1 ps / 1 ps

(* BLOCK_STUB = "true" *)
module xadc_wiz_0 (
  di_in,
  daddr_in,
  den_in,
  dwe_in,
  drdy_out,
  do_out,
  dclk_in,
  reset_in,
  vp_in,
  vn_in,
  vauxp0,
  vauxn0,
  user_temp_alarm_out,
  vccint_alarm_out,
  vccaux_alarm_out,
  ot_out,
  channel_out,
  eoc_out,
  alarm_out,
  eos_out,
  busy_out
);

  (* X_INTERFACE_INFO = "xilinx.com:interface:drp:1.0 s_drp DI" *)
  (* X_INTERFACE_MODE = "slave s_drp" *)
  input [15:0]di_in;
  (* X_INTERFACE_INFO = "xilinx.com:interface:drp:1.0 s_drp DADDR" *)
  input [6:0]daddr_in;
  (* X_INTERFACE_INFO = "xilinx.com:interface:drp:1.0 s_drp DEN" *)
  input den_in;
  (* X_INTERFACE_INFO = "xilinx.com:interface:drp:1.0 s_drp DWE" *)
  input dwe_in;
  (* X_INTERFACE_INFO = "xilinx.com:interface:drp:1.0 s_drp DRDY" *)
  output drdy_out;
  (* X_INTERFACE_INFO = "xilinx.com:interface:drp:1.0 s_drp DO" *)
  output [15:0]do_out;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 dclk_in CLK" *)
  (* X_INTERFACE_MODE = "slave dclk_in" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME dclk_in, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, CLK_DOMAIN , ASSOCIATED_BUSIF , ASSOCIATED_PORT , ASSOCIATED_RESET , INSERT_VIP 0" *)
  input dclk_in;
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 reset_in RST" *)
  (* X_INTERFACE_MODE = "slave reset_in" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME reset_in, POLARITY ACTIVE_HIGH, INSERT_VIP 0" *)
  input reset_in;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 Vp_Vn V_P" *)
  (* X_INTERFACE_MODE = "slave Vp_Vn" *)
  input vp_in;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 Vp_Vn V_N" *)
  input vn_in;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 Vaux0 V_P" *)
  (* X_INTERFACE_MODE = "slave Vaux0" *)
  input vauxp0;
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_analog_io:1.0 Vaux0 V_N" *)
  input vauxn0;
  (* X_INTERFACE_IGNORE = "true" *)
  output user_temp_alarm_out;
  (* X_INTERFACE_IGNORE = "true" *)
  output vccint_alarm_out;
  (* X_INTERFACE_IGNORE = "true" *)
  output vccaux_alarm_out;
  (* X_INTERFACE_IGNORE = "true" *)
  output ot_out;
  (* X_INTERFACE_IGNORE = "true" *)
  output [4:0]channel_out;
  (* X_INTERFACE_IGNORE = "true" *)
  output eoc_out;
  (* X_INTERFACE_IGNORE = "true" *)
  output alarm_out;
  (* X_INTERFACE_IGNORE = "true" *)
  output eos_out;
  (* X_INTERFACE_IGNORE = "true" *)
  output busy_out;

  // stub module has no contents

endmodule
