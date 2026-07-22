`timescale 1ns/1ps

`include "fakeram7_256x8.v"

module slowpath_top #(
  parameter N_PERSP     = 7,
  parameter IDX_W       = 8,
  parameter W_BITS      = 8,
  parameter X_DIM       = 16,
  parameter H_DIM       = 8,
  parameter ACC_W       = 24,
  parameter K_LOG2      = 6,
  parameter THETA_SHIFT = 6
)(
  input  logic                        clk,
  input  logic                        rst_n,

  input  logic                        obs_valid,
  output logic                        obs_ready,
  input  logic [N_PERSP*W_BITS-1:0]   obs_weights_i,
  input  logic [N_PERSP*IDX_W-1:0]    obs_idx_i,
  input  logic signed [11:0]          obs_sum_i,
  input  logic                        obs_pred_i,
  input  logic                        obs_low_conf_i,
  input  logic [2:0]                  obs_reuse_bucket_i,
  input  logic                        obs_outcome_i,

  output logic                        tune_valid,
  input  logic                        tune_ack,
  output logic [N_PERSP*8-1:0]        gates_o,
  output logic [10:0]                 theta_o,
  output logic [7:0]                  tune_epoch,

  output logic                        lbl_valid,
  input  logic                        lbl_ready,
  output logic                        lbl_dir,
  output logic [N_PERSP*IDX_W-1:0]    lbl_idx,

  input  logic [1:0]                  mode_i,

  input  logic                        flush_i,
  input  logic                        gw_we,
  input  logic [1:0]                  gw_bank,
  input  logic [IDX_W-1:0]            gw_addr,
  input  logic [7:0]                  gw_wdata,

  output logic                        busy,
  output logic                        idle,
  output logic [15:0]                 obs_seen,
  output logic [15:0]                 obs_dropped,
  output logic [15:0]                 agree_cnt
);

  localparam int A_W_END   = X_DIM*H_DIM - 1;
  localparam int A_U_BASE  = 128;
  localparam int A_U_END   = A_U_BASE + H_DIM*H_DIM-1;
  localparam int A_B_BASE  = 192;
  localparam int A_B_END   = A_B_BASE + H_DIM - 1;
  localparam int A_HW_BASE = 200;
  localparam int A_HW_END  = A_HW_BASE + 3*H_DIM - 1;
  localparam int A_HB_BASE = 224;
  localparam int A_HB_END  = A_HB_BASE + 2;

  function automatic [15:0] sig_lut(input [6:0] i);
    case (i)
      7'd0 : sig_lut = 16'd11;    7'd1 : sig_lut = 16'd14;
      7'd2 : sig_lut = 16'd18;    7'd3 : sig_lut = 16'd23;
      7'd4 : sig_lut = 16'd30;    7'd5 : sig_lut = 16'd38;
      7'd6 : sig_lut = 16'd49;    7'd7 : sig_lut = 16'd63;
      7'd8 : sig_lut = 16'd81;    7'd9 : sig_lut = 16'd104;
      7'd10: sig_lut = 16'd133;   7'd11: sig_lut = 16'd171;
      7'd12: sig_lut = 16'd219;   7'd13: sig_lut = 16'd281;
      7'd14: sig_lut = 16'd360;   7'd15: sig_lut = 16'd461;
      7'd16: sig_lut = 16'd589;   7'd17: sig_lut = 16'd753;
      7'd18: sig_lut = 16'd961;   7'd19: sig_lut = 16'd1223;
      7'd20: sig_lut = 16'd1554;  7'd21: sig_lut = 16'd1969;
      7'd22: sig_lut = 16'd2486;  7'd23: sig_lut = 16'd3124;
      7'd24: sig_lut = 16'd3906;  7'd25: sig_lut = 16'd4851;
      7'd26: sig_lut = 16'd5978;  7'd27: sig_lut = 16'd7297;
      7'd28: sig_lut = 16'd8813;  7'd29: sig_lut = 16'd10513;
      7'd30: sig_lut = 16'd12371; 7'd31: sig_lut = 16'd14347;
      7'd32: sig_lut = 16'd16384; 7'd33: sig_lut = 16'd18421;
      7'd34: sig_lut = 16'd20397; 7'd35: sig_lut = 16'd22255;
      7'd36: sig_lut = 16'd23955; 7'd37: sig_lut = 16'd25471;
      7'd38: sig_lut = 16'd26790; 7'd39: sig_lut = 16'd27917;
      7'd40: sig_lut = 16'd28862; 7'd41: sig_lut = 16'd29644;
      7'd42: sig_lut = 16'd30282; 7'd43: sig_lut = 16'd30799;
      7'd44: sig_lut = 16'd31214; 7'd45: sig_lut = 16'd31545;
      7'd46: sig_lut = 16'd31807; 7'd47: sig_lut = 16'd32015;
      7'd48: sig_lut = 16'd32179; 7'd49: sig_lut = 16'd32307;
      7'd50: sig_lut = 16'd32408; 7'd51: sig_lut = 16'd32487;
      7'd52: sig_lut = 16'd32549; 7'd53: sig_lut = 16'd32597;
      7'd54: sig_lut = 16'd32635; 7'd55: sig_lut = 16'd32664;
      7'd56: sig_lut = 16'd32687; 7'd57: sig_lut = 16'd32705;
      7'd58: sig_lut = 16'd32719; 7'd59: sig_lut = 16'd32730;
      7'd60: sig_lut = 16'd32738; 7'd61: sig_lut = 16'd32745;
      7'd62: sig_lut = 16'd32750; 7'd63: sig_lut = 16'd32754;
      7'd64: sig_lut = 16'd32757;
      default: sig_lut = 16'd0;
    endcase
  endfunction

  // activation
  function automatic signed [8:0] act_f(input signed [ACC_W-1:0] a,
                                        input logic is_tanh);
    logic signed [ACC_W-1:0] t;
    logic [6:0]              i;
    logic [15:0]             lo, hi;
    logic [11:0]             frac;
    logic [27:0]             mul;
    logic [15:0]             v;
    logic signed [17:0]      tv;
    begin
      t = is_tanh ? (a >>> 10) : (a >>> 11);
      if (t >= 31) begin
        act_f = is_tanh ? 9'sd127 : 9'sd128;
      end else if (t < -32) begin
        act_f = is_tanh ? -9'sd128 : 9'sd0;
      end else begin
        i    = 7'(t + 32);
        lo   = sig_lut(i);
        hi   = sig_lut(i + 7'd1);
        frac = is_tanh ? 12'(a - (t <<< 10)) : 12'(a - (t <<< 11));
        mul  = (hi - lo) * frac;
        v    = 16'(lo + (is_tanh ? (mul >> 10) : (mul >> 11)));
        if (is_tanh) begin
          tv    = ($signed({2'b00, v}) <<< 1) - 18'sd32768 + 18'sd128;
          tv    = tv >>> 8;
          act_f = (tv >  18'sd127) ?  9'sd127 :
                  (tv < -18'sd128) ? -9'sd128 : 9'(tv);
        end else begin
          act_f = 9'((v + 16'd128) >> 8);
        end
      end
    end
  endfunction

  function automatic signed [ACC_W-1:0] mac_term(input [7:0] w,
                                                 input signed [7:0] v);
    logic signed [15:0] p;
    begin
      p        = $signed(w) * v;
      mac_term = ACC_W'(p);
    end
  endfunction

  function automatic signed [ACC_W-1:0] bias_term(input [7:0] b);
    bias_term = ACC_W'($signed(b)) <<< 7;
  endfunction

  function automatic signed [7:0] rh_mul(input [7:0] r, input signed [7:0] h);
    logic signed [17:0] p;
    begin
      p      = $signed({1'b0, r}) * h;
      rh_mul = 8'(p >>> 7);
    end
  endfunction

  function automatic signed [7:0] blend(input [7:0] z,
                                        input signed [7:0] h,
                                        input signed [8:0] n);
    logic signed [17:0] t1, t2, p;
    begin
      t1    = $signed({1'b0, 8'd128 - z}) * h;
      t2    = $signed({1'b0, z}) * n;
      p     = t1 + t2;
      blend = 8'(p >>> 7);
    end
  endfunction

  logic [N_PERSP*W_BITS-1:0] ow_q;
  logic [N_PERSP*IDX_W-1:0]  oi_q;
  logic signed [11:0]        os_q;
  logic                      op_q, ol_q, oo_q;
  logic [2:0]                ob_q;

  logic signed [7:0] xv [X_DIM];

  always_comb begin
    for (int d = 0; d < X_DIM; d++) xv[d] = 8'sd0;

    for (int k = 0; k < N_PERSP; k++) xv[k] = $signed(ow_q[k*W_BITS +: W_BITS]);

    xv[7]  = 8'($signed(os_q) >>> 4);
    xv[8]  = op_q ? 8'sd127 : -8'sd128;
    xv[9]  = ol_q ? 8'sd127 :  8'sd0;
    xv[10] = oo_q ? 8'sd127 : -8'sd128;

    xv[11] = (op_q == oo_q) ? 8'sd127 : -8'sd128;
    xv[12] = 8'($signed({1'b0, ob_q, 4'b0000}));
    xv[13] = 8'sd127;

  end

  typedef enum logic [3:0] {
    S_IDLE, S_P1, S_ACTZ, S_ACTR, S_P2, S_ACTN, S_HEAD, S_ACTO, S_EMIT
  } st_t;
  st_t st;

  // bank streaming
  logic [7:0] ad;
  logic [3:0] ac;
  logic       str_en;

  always_comb begin
    str_en = (st == S_P1) || (st == S_P2) || (st == S_HEAD);
  end

  logic [7:0] ad_d;
  st_t        ph_d;
  logic       v_d;

  logic [W_BITS-1:0] rd [3];

  logic gw_active;
  assign gw_active = gw_we && (st == S_IDLE);

  logic              bank_ce [3];
  logic              bank_we [3];
  logic [IDX_W-1:0]  bank_ad [3];
  logic [W_BITS-1:0] bank_wd [3];

  always_comb begin
    for (int g = 0; g < 3; g++) begin
      bank_ce[g] = 1'b0;
      bank_we[g] = 1'b0;
      bank_ad[g] = '0;
      bank_wd[g] = '0;
      if (gw_active) begin
        bank_ce[g] = (gw_bank == 2'(g));
        bank_we[g] = 1'b1;
        bank_ad[g] = gw_addr;
        bank_wd[g] = gw_wdata;
      end else if (str_en) begin
        bank_ce[g] = 1'b1;
        bank_ad[g] = ad;
      end
    end
  end

  generate
    for (genvar gb = 0; gb < 3; gb++) begin : g_gru_banks
      fakeram7_256x8 u_bank (
        .rd_out (rd[gb]),
        .addr_in(bank_ad[gb]),
        .we_in  (bank_we[gb]),
        .wd_in  (bank_wd[gb]),
        .clk    (clk),
        .ce_in  (bank_ce[gb])
      );
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ad_d <= '0;
      ph_d <= S_IDLE;
      v_d  <= 1'b0;
    end else begin
      ad_d <= ad;
      ph_d <= st;
      v_d  <= str_en && !gw_active;
    end
  end

  // accumulators
  logic signed [ACC_W-1:0] acc_z [H_DIM];
  logic signed [ACC_W-1:0] acc_r [H_DIM];
  logic signed [ACC_W-1:0] acc_n [H_DIM];
  logic signed [ACC_W-1:0] acc_o [9];

  logic [7:0]        zv  [H_DIM];
  logic [7:0]        rv  [H_DIM];
  logic signed [7:0] rh  [H_DIM];
  logic signed [7:0] hst [H_DIM];

  logic [7:0]  gates_q [N_PERSP];
  logic [10:0] theta_q;
  logic        lbl_dir_q;
  logic [K_LOG2-1:0] obs_cnt;
  logic        tick;
  logic        lbl_req, tune_req, lbl_done, tune_done;
  logic        obs_valid_d;

  logic [2:0] h_w, h_u, j_u, j_hd;
  logic [3:0] d_w;
  logic [1:0] row_hd;
  always_comb begin
    h_w    = ad_d[6:4];
    d_w    = ad_d[3:0];
    h_u    = ad_d[5:3];
    j_u    = ad_d[2:0];
    row_hd = 2'((ad_d - 8'(A_HW_BASE)) >> 3);
    j_hd   = 3'(ad_d - 8'(A_HW_BASE));
  end

  logic signed [ACC_W-1:0] act_in;
  logic                    act_mode;
  logic signed [8:0]       act_out;

  always_comb begin
    case (st)
      S_ACTZ:  act_in = acc_z[ac[2:0]];
      S_ACTR:  act_in = acc_r[ac[2:0]];
      S_ACTN:  act_in = acc_n[ac[2:0]];
      default: act_in = acc_o[ac];
    endcase
    act_mode = (st == S_ACTN);
  end
  assign act_out = act_f(act_in, act_mode);

  assign obs_ready  = (st == S_IDLE) && (mode_i != 2'd0) && !gw_we;
  assign busy       = (st != S_IDLE);
  assign idle       = (st == S_IDLE);
  assign tune_valid = (st == S_EMIT) && tune_req && !tune_done;
  assign lbl_valid  = (st == S_EMIT) && lbl_req  && !lbl_done;
  assign lbl_dir    = lbl_dir_q;
  assign lbl_idx    = oi_q;
  assign theta_o    = theta_q;
  for (genvar gg = 0; gg < N_PERSP; gg++) begin : g_gates_o
    assign gates_o[gg*8 +: 8] = gates_q[gg];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st          <= S_IDLE;
      ad          <= '0;
      ac          <= '0;
      obs_cnt     <= '0;
      tick        <= 1'b0;
      tune_epoch  <= '0;
      theta_q     <= '0;
      lbl_dir_q   <= 1'b0;
      lbl_req     <= 1'b0;
      tune_req    <= 1'b0;
      lbl_done    <= 1'b0;
      tune_done   <= 1'b0;
      obs_seen    <= '0;
      obs_dropped <= '0;
      agree_cnt   <= '0;
      obs_valid_d <= 1'b0;
      ow_q        <= '0;
      oi_q        <= '0;
      os_q        <= '0;
      op_q        <= 1'b0;
      ol_q        <= 1'b0;
      oo_q        <= 1'b0;
      ob_q        <= '0;
      for (int h = 0; h < H_DIM; h++) begin
        hst[h] <= 8'sd0;
        zv[h]  <= 8'd0;
        rv[h]  <= 8'd0;
        rh[h]  <= 8'sd0;
        acc_z[h] <= '0;
        acc_r[h] <= '0;
        acc_n[h] <= '0;
      end
      for (int o = 0; o < 9; o++) acc_o[o] <= '0;
      for (int k = 0; k < N_PERSP; k++) gates_q[k] <= 8'h80;
    end else begin
      obs_valid_d <= obs_valid;

      if (obs_valid && !obs_ready && !obs_valid_d) obs_dropped <= obs_dropped + 1'b1;

      if (flush_i) begin
        st       <= S_IDLE;
        obs_cnt  <= '0;
        lbl_req  <= 1'b0;
        tune_req <= 1'b0;
        for (int h = 0; h < H_DIM; h++) hst[h] <= 8'sd0;
      end else begin

        if (v_d) begin
          case (ph_d)
            S_P1: begin
              if (ad_d <= 8'(A_W_END)) begin
                acc_z[h_w] <= acc_z[h_w] + mac_term(rd[0], xv[d_w]);
                acc_r[h_w] <= acc_r[h_w] + mac_term(rd[1], xv[d_w]);
                acc_n[h_w] <= acc_n[h_w] + mac_term(rd[2], xv[d_w]);
              end else if (ad_d <= 8'(A_U_END)) begin

                acc_z[h_u] <= acc_z[h_u] + mac_term(rd[0], hst[j_u]);
                acc_r[h_u] <= acc_r[h_u] + mac_term(rd[1], hst[j_u]);
              end else begin
                acc_z[ad_d[2:0]] <= acc_z[ad_d[2:0]] + bias_term(rd[0]);
                acc_r[ad_d[2:0]] <= acc_r[ad_d[2:0]] + bias_term(rd[1]);
                acc_n[ad_d[2:0]] <= acc_n[ad_d[2:0]] + bias_term(rd[2]);
              end
            end
            S_P2: begin
              acc_n[h_u] <= acc_n[h_u] + mac_term(rd[2], rh[j_u]);
            end
            S_HEAD: begin
              if (ad_d <= 8'(A_HW_END)) begin
                acc_o[{1'b0, row_hd}]       <= acc_o[{1'b0, row_hd}]
                                             + mac_term(rd[0], hst[j_hd]);
                acc_o[4'(row_hd) + 4'd3]    <= acc_o[4'(row_hd) + 4'd3]
                                             + mac_term(rd[1], hst[j_hd]);
                acc_o[4'(row_hd) + 4'd6]    <= acc_o[4'(row_hd) + 4'd6]
                                             + mac_term(rd[2], hst[j_hd]);
              end else begin
                acc_o[4'(ad_d - 8'(A_HB_BASE))]        <=
                  acc_o[4'(ad_d - 8'(A_HB_BASE))]        + bias_term(rd[0]);
                acc_o[4'(ad_d - 8'(A_HB_BASE)) + 4'd3] <=
                  acc_o[4'(ad_d - 8'(A_HB_BASE)) + 4'd3] + bias_term(rd[1]);
                acc_o[4'(ad_d - 8'(A_HB_BASE)) + 4'd6] <=
                  acc_o[4'(ad_d - 8'(A_HB_BASE)) + 4'd6] + bias_term(rd[2]);
              end
            end
            default: ;
          endcase
        end

        case (st)
          S_IDLE: begin
            if (obs_valid && obs_ready) begin
              ow_q <= obs_weights_i;
              oi_q <= obs_idx_i;
              os_q <= obs_sum_i;
              op_q <= obs_pred_i;
              ol_q <= obs_low_conf_i;
              oo_q <= obs_outcome_i;
              ob_q <= obs_reuse_bucket_i;
              obs_seen <= obs_seen + 1'b1;
              if (obs_pred_i == obs_outcome_i) agree_cnt <= agree_cnt + 1'b1;
              for (int h = 0; h < H_DIM; h++) begin
                acc_z[h] <= '0; acc_r[h] <= '0; acc_n[h] <= '0;
              end
              for (int o = 0; o < 9; o++) acc_o[o] <= '0;
              tick      <= (obs_cnt == {K_LOG2{1'b1}});
              obs_cnt   <= obs_cnt + 1'b1;
              lbl_done  <= 1'b0;
              tune_done <= 1'b0;
              ad        <= '0;
              st        <= S_P1;
            end
          end

          S_P1: begin
            if (ad == 8'(A_B_END)) begin
              ad <= '0;
              ac <= '0;
              st <= S_ACTZ;
            end else begin
              ad <= ad + 8'd1;
            end
          end

          S_ACTZ: begin
            zv[ac[2:0]] <= 8'(act_out);
            if (ac == 4'(H_DIM-1)) begin ac <= '0; st <= S_ACTR; end
            else                        ac <= ac + 4'd1;
          end

          S_ACTR: begin
            rv[ac[2:0]] <= 8'(act_out);

            rh[ac[2:0]] <= rh_mul(8'(act_out), hst[ac[2:0]]);
            if (ac == 4'(H_DIM-1)) begin ac <= '0; ad <= 8'(A_U_BASE); st <= S_P2; end
            else                        ac <= ac + 4'd1;
          end

          S_P2: begin
            if (ad == 8'(A_U_END)) begin ad <= '0; ac <= '0; st <= S_ACTN; end
            else                        ad <= ad + 8'd1;
          end

          S_ACTN: begin

            hst[ac[2:0]] <= blend(zv[ac[2:0]], hst[ac[2:0]], act_out);
            if (ac == 4'(H_DIM-1)) begin ac <= '0; ad <= 8'(A_HW_BASE); st <= S_HEAD; end
            else                        ac <= ac + 4'd1;
          end

          S_HEAD: begin
            if (ad == 8'(A_HB_END)) begin ad <= '0; ac <= '0; st <= S_ACTO; end
            else                         ad <= ad + 8'd1;
          end

          S_ACTO: begin

            if (ac <= 4'd6) begin
              if (tick) gates_q[ac[2:0]] <= 8'(act_out);
            end else if (ac == 4'd7) begin
              if (tick) begin
                if (acc_o[7][ACC_W-1])                          theta_q <= 11'd0;
                else if ((acc_o[7] >>> THETA_SHIFT) > 24'sd2047) theta_q <= 11'd2047;
                else                                             theta_q <= 11'(acc_o[7] >>> THETA_SHIFT);
              end
            end else begin
              lbl_dir_q <= ~acc_o[8][ACC_W-1];
            end
            if (ac == 4'd8) begin
              lbl_req  <= (mode_i == 2'd3);
              tune_req <= (mode_i >= 2'd2) && tick;

              if (tick) tune_epoch <= tune_epoch + 1'b1;
              st       <= S_EMIT;
            end else begin
              ac <= ac + 4'd1;
            end
          end

          S_EMIT: begin
            if (lbl_valid  && lbl_ready) lbl_done  <= 1'b1;
            if (tune_valid && tune_ack)  tune_done <= 1'b1;
            if ((lbl_done  || !lbl_req  || (lbl_valid  && lbl_ready)) &&
                (tune_done || !tune_req || (tune_valid && tune_ack))) begin
              lbl_req  <= 1'b0;
              tune_req <= 1'b0;
              st       <= S_IDLE;
            end
          end

          default: st <= S_IDLE;
        endcase
      end
    end
  end

endmodule
