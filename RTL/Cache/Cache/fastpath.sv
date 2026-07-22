`timescale 1ns/1ps

`include "fakeram7_256x8.v"

module fastpath_top #(
  parameter N_PERSP   = 7,
  parameter IDX_W     = 8,
  parameter W_BITS    = 8,
  parameter EVT_DEPTH = 4
)(
  input  logic                        clk,
  input  logic                        rst_n,

  input  logic                        req_valid,
  input  logic [31:0]                 pc_i,
  input  logic [47:0]                 addr_i,
  input  logic [7:0]                  set_idx_i,
  input  logic [31:0]                 pc_hist_i,
  input  logic [2:0]                  reuse_bucket_i,

  input  logic [N_PERSP*8-1:0]        gates_i,
  input  logic [10:0]                 theta_i,

  input  logic                        train_valid,
  input  logic                        train_dir,
  input  logic [N_PERSP*IDX_W-1:0]    train_idx_i,
  output logic                        train_ready,
  output logic                        upd_idle,

  input  logic                        dbg_we,
  input  logic [N_PERSP-1:0]          dbg_mask,
  input  logic [IDX_W-1:0]            dbg_addr,
  input  logic [W_BITS-1:0]           dbg_wdata,

  output logic                        out_valid,
  output logic signed [11:0]          out_sum,
  output logic                        out_pred,
  output logic                        out_low_conf,

  output logic [N_PERSP*W_BITS-1:0]   obs_weights,
  output logic [N_PERSP*IDX_W-1:0]    obs_idx
);

  // hashing
  function automatic [IDX_W-1:0] fold32(input [31:0] x);
    fold32 = x[7:0] ^ x[15:8] ^ x[23:16] ^ x[31:24];
  endfunction

  logic [31:0] pc2, a6, tag, ph3;
  assign pc2 = {2'b00, pc_i[31:2]};
  assign a6  = addr_i[37:6];
  assign tag = addr_i[43:12];
  assign ph3 = {pc_hist_i[28:0], 3'b000};

  logic [IDX_W-1:0] hash_idx [N_PERSP];
  assign hash_idx[0] = fold32(pc2);
  assign hash_idx[1] = fold32(pc2 ^ a6);
  assign hash_idx[2] = fold32(a6);
  assign hash_idx[3] = fold32(tag ^ {24'b0, set_idx_i});
  assign hash_idx[4] = fold32(pc_hist_i);
  assign hash_idx[5] = fold32(ph3 ^ a6);
  assign hash_idx[6] = fold32({24'b0, reuse_bucket_i, 5'b00000} ^ pc2 ^ {24'b0, set_idx_i});

  // training event fifo
  logic                       evt_dir_q [EVT_DEPTH];
  logic [N_PERSP*IDX_W-1:0]   evt_idx_q [EVT_DEPTH];
  logic [$clog2(EVT_DEPTH):0] evt_cnt;
  logic [$clog2(EVT_DEPTH)-1:0] evt_wp, evt_rp;
  logic                       evt_push, evt_pop;

  assign train_ready = (evt_cnt != EVT_DEPTH);
  assign evt_push    = train_valid && train_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      evt_cnt <= '0;
      evt_wp  <= '0;
      evt_rp  <= '0;
    end else begin
      if (evt_push) begin
        evt_dir_q[evt_wp] <= train_dir;
        evt_idx_q[evt_wp] <= train_idx_i;
        evt_wp            <= evt_wp + 1'b1;
      end
      if (evt_pop) begin
        evt_rp <= evt_rp + 1'b1;
      end
      evt_cnt <= evt_cnt + (evt_push ? 1'b1 : 1'b0) - (evt_pop ? 1'b1 : 1'b0);
    end
  end

  logic             head_dir;
  logic [IDX_W-1:0] head_idx [N_PERSP];
  assign head_dir = evt_dir_q[evt_rp];
  for (genvar gi = 0; gi < N_PERSP; gi++) begin : g_evtidx
    assign head_idx[gi] = evt_idx_q[evt_rp][gi*IDX_W +: IDX_W];
  end

  typedef enum logic [1:0] {U_IDLE, U_CAP, U_WR} ustate_t;
  ustate_t ust;

  logic banks_free;
  assign banks_free = !dbg_we && !req_valid;

  logic [W_BITS-1:0] bank_rdata [N_PERSP];

  // weight update
  function automatic [W_BITS-1:0] sat_step(input [W_BITS-1:0] w, input logic dir);
    logic signed [W_BITS:0] s;
    s = $signed({w[W_BITS-1], w}) + (dir ? 9'sd1 : -9'sd1);
    if      (s >  9'sd127)  sat_step = 8'h7F;
    else if (s < -9'sd128)  sat_step = 8'h80;
    else                    sat_step = s[W_BITS-1:0];
  endfunction

  logic [W_BITS-1:0] new_w_c [N_PERSP];
  logic [W_BITS-1:0] new_w_q [N_PERSP];
  for (genvar gc = 0; gc < N_PERSP; gc++) begin : g_rmw
    assign new_w_c[gc] = sat_step(bank_rdata[gc], head_dir);
  end

  logic upd_rd_en, upd_wr_en;
  logic [W_BITS-1:0] upd_wdata [N_PERSP];

  always_comb begin
    upd_rd_en = 1'b0;
    upd_wr_en = 1'b0;
    for (int k = 0; k < N_PERSP; k++) begin
      upd_wdata[k] = new_w_c[k];
    end
    case (ust)
      U_IDLE: upd_rd_en = (evt_cnt != 0) && banks_free;
      U_CAP:  upd_wr_en = banks_free;
      U_WR: begin
        upd_wr_en = banks_free;
        for (int k = 0; k < N_PERSP; k++) begin
          upd_wdata[k] = new_w_q[k];
        end
      end
      default: ;
    endcase
  end

  assign evt_pop  = upd_wr_en;
  assign upd_idle = (ust == U_IDLE) && (evt_cnt == 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ust <= U_IDLE;
    end else begin
      case (ust)
        U_IDLE: begin
          if (upd_rd_en) ust <= U_CAP;
        end
        U_CAP:  begin
          if (upd_wr_en) begin
            ust <= U_IDLE;
          end else begin
            for (int k = 0; k < N_PERSP; k++) begin
              new_w_q[k] <= new_w_c[k];
            end
            ust <= U_WR;
          end
        end
        U_WR:   begin
          if (upd_wr_en) ust <= U_IDLE;
        end
        default: ust <= U_IDLE;
      endcase
    end
  end

  // bank port arbitration
  logic              bank_ce  [N_PERSP];
  logic              bank_we  [N_PERSP];
  logic [IDX_W-1:0]  bank_ad  [N_PERSP];
  logic [W_BITS-1:0] bank_wd  [N_PERSP];

  always_comb begin
    for (int k = 0; k < N_PERSP; k++) begin
      bank_ce[k] = 1'b0;
      bank_we[k] = 1'b0;
      bank_ad[k] = '0;
      bank_wd[k] = '0;
      if (dbg_we) begin
        bank_ce[k] = dbg_mask[k];
        bank_we[k] = 1'b1;
        bank_ad[k] = dbg_addr;
        bank_wd[k] = dbg_wdata;
      end else if (req_valid) begin
        bank_ce[k] = 1'b1;
        bank_ad[k] = hash_idx[k];
      end else if (upd_rd_en) begin
        bank_ce[k] = 1'b1;
        bank_ad[k] = head_idx[k];
      end else if (upd_wr_en) begin
        bank_ce[k] = 1'b1;
        bank_we[k] = 1'b1;
        bank_ad[k] = head_idx[k];
        bank_wd[k] = upd_wdata[k];
      end
    end
  end

  generate
    for (genvar gb = 0; gb < N_PERSP; gb++) begin : g_banks
      fakeram7_256x8 u_bank (
        .rd_out (bank_rdata[gb]),
        .addr_in(bank_ad[gb]),
        .we_in  (bank_we[gb]),
        .wd_in  (bank_wd[gb]),
        .clk    (clk),
        .ce_in  (bank_ce[gb])
      );
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) out_valid <= 1'b0;
    else        out_valid <= req_valid;
  end

  // gated dot product
  logic signed [8:0]  gate_scaled [N_PERSP];
  logic signed [7:0]  weight_val  [N_PERSP];
  logic signed [16:0] prod        [N_PERSP];
  logic signed [11:0] term        [N_PERSP];

  for (genvar gp = 0; gp < N_PERSP; gp++) begin : g_prod
    assign gate_scaled[gp] = $signed({1'b0, gates_i[gp*8 +: 8]});
    assign weight_val[gp]  = $signed(bank_rdata[gp]);
    assign prod[gp]        = gate_scaled[gp] * weight_val[gp];
    assign term[gp]        = 12'(prod[gp] >>> 7);
  end

  logic signed [11:0] sum_l1_0, sum_l1_1, sum_l1_2, sum_l1_3;
  logic signed [11:0] sum_l2_0, sum_l2_1;
  logic signed [11:0] acc;

  assign sum_l1_0 = term[0] + term[1];
  assign sum_l1_1 = term[2] + term[3];
  assign sum_l1_2 = term[4] + term[5];
  assign sum_l1_3 = term[6];

  assign sum_l2_0 = sum_l1_0 + sum_l1_1;
  assign sum_l2_1 = sum_l1_2 + sum_l1_3;

  assign acc      = sum_l2_0 + sum_l2_1;

  assign out_sum  = acc;
  assign out_pred = ~acc[11];

  logic signed [11:0] theta_signed;
  logic signed [11:0] neg_theta_signed;

  assign theta_signed     = $signed({1'b0, theta_i});
  assign neg_theta_signed = -theta_signed;

  assign out_low_conf     = (acc < theta_signed) && (acc > neg_theta_signed);

  for (genvar gw = 0; gw < N_PERSP; gw++) begin : g_obs_w
    assign obs_weights[gw*W_BITS +: W_BITS] = bank_rdata[gw];
  end

  logic [N_PERSP*IDX_W-1:0] hash_idx_packed;
  for (genvar gh = 0; gh < N_PERSP; gh++) begin : g_hash_pack
    assign hash_idx_packed[gh*IDX_W +: IDX_W] = hash_idx[gh];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)         obs_idx <= '0;
    else if (req_valid) obs_idx <= hash_idx_packed;
  end

endmodule
