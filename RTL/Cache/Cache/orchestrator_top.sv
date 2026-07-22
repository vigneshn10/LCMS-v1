`timescale 1ns/1ps
`default_nettype none

`include "fastpath.sv"
`include "slowpath.sv"

module orchestrator_top #(
  parameter N_PERSP       = 7,
  parameter IDX_W         = 8,
  parameter W_BITS        = 8,
  parameter ST_DEPTH_LOG2 = 6,
  parameter TAG_W         = 8,
  parameter WARMUP_OBS    = 32,
  parameter SAMPLE_LOG2   = 2
)(
  input  wire                        clk,
  input  wire                        rst_n,

  input  wire                        req_valid,
  input  wire [31:0]                 pc_i,
  input  wire [47:0]                 addr_i,
  input  wire [7:0]                  set_idx_i,
  input  wire [31:0]                 pc_hist_i,
  input  wire [2:0]                  reuse_bucket_i,
  output wire                        out_valid,
  output wire signed [11:0]          out_sum,
  output wire                        out_pred,
  output wire                        out_low_conf,

  input  wire                        outcome_valid,
  input  wire [47:0]                 outcome_addr,
  input  wire                        outcome_i,

  input  wire                        csr_mode_force_en,
  input  wire [1:0]                  csr_mode_force,
  input  wire                        flush_i,

  input  wire                        bd_we,
  input  wire                        bd_target,
  input  wire [N_PERSP-1:0]          bd_fp_mask,
  input  wire [1:0]                  bd_sp_bank,
  input  wire [7:0]                  bd_addr,
  input  wire [7:0]                  bd_wdata,

  output wire [1:0]                  mode_o,
  output wire [15:0]                 st_alloc_o,
  output wire [15:0]                 st_complete_o,
  output wire [15:0]                 st_evict_o,
  output wire [15:0]                 st_drop_o,
  output wire [15:0]                 tunes_applied_o,
  output wire [15:0]                 obs_seen_o,
  output wire [15:0]                 agree_cnt_o,
  output wire [7:0]                  epoch_o
);

  localparam int ST_DEPTH = (1 << ST_DEPTH_LOG2);

  localparam [1:0] M_OFF = 2'd0, M_OBS = 2'd1, M_TUNE = 2'd2, M_TUNELBL = 2'd3;

  logic [1:0]  mode_q;
  logic [15:0] warmup_ctr;

  assign mode_o = mode_q;

  logic [15:0] sp_obs_seen, sp_obs_dropped, sp_agree_cnt;
  logic        sp_busy, sp_idle;

  logic [N_PERSP*8-1:0] gates_applied;
  logic [10:0]          theta_applied;
  logic [7:0]           epoch_applied;
  logic [15:0]          tunes_applied;

  assign tunes_applied_o = tunes_applied;
  assign epoch_o         = epoch_applied;

  logic                 sp_tune_valid;
  logic [N_PERSP*8-1:0] sp_gates_o;
  logic [10:0]          sp_theta_o;
  logic [7:0]           sp_tune_epoch;

  logic                    st_valid   [ST_DEPTH];
  logic [TAG_W-1:0]        st_tag     [ST_DEPTH];
  logic [N_PERSP*W_BITS-1:0] st_weights [ST_DEPTH];
  logic [N_PERSP*IDX_W-1:0]  st_idx     [ST_DEPTH];
  logic signed [11:0]      st_sum     [ST_DEPTH];
  logic                    st_pred    [ST_DEPTH];
  logic                    st_lowconf [ST_DEPTH];
  logic [2:0]              st_bucket  [ST_DEPTH];

  logic [15:0] st_alloc, st_complete, st_evict, st_drop;
  logic [ST_DEPTH_LOG2-1:0] alloc_ctr;

  assign st_alloc_o    = st_alloc;
  assign st_complete_o = st_complete;
  assign st_evict_o    = st_evict;
  assign st_drop_o     = st_drop;

  logic                     fp_out_valid;
  logic signed [11:0]       fp_out_sum;
  logic                     fp_out_pred;
  logic                     fp_out_low_conf;
  logic [N_PERSP*IDX_W-1:0] fp_obs_idx;
  logic [N_PERSP*W_BITS-1:0] fp_obs_weights;
  logic                     fp_train_ready;
  logic                     fp_upd_idle;

  logic [47:0] addr_d;
  logic [2:0]  bucket_d;

  // mode fsm
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin addr_d <= '0; bucket_d <= '0; end
    else if (req_valid) begin addr_d <= addr_i; bucket_d <= reuse_bucket_i; end
  end

  // tag / index helpers
  function automatic [7:0] fold48(input [47:0] a);
    fold48 = a[7:0] ^ a[15:8] ^ a[23:16] ^ a[31:24] ^ a[39:32] ^ a[47:40];
  endfunction
  function automatic [ST_DEPTH_LOG2-1:0] st_index(input [47:0] a);
    logic [7:0] f;
    begin
      f = fold48(a);
      st_index = f[ST_DEPTH_LOG2-1:0];
    end
  endfunction
  function automatic [TAG_W-1:0] st_tagf(input [47:0] a);
    st_tagf = ((a >> 6) ^ (a >> 14)) & ((1 << TAG_W) - 1);
  endfunction

  wire alloc_take = (alloc_ctr[SAMPLE_LOG2-1:0] == '0) && (mode_q != M_OFF);
  wire do_alloc   = fp_out_valid && alloc_take;
  wire [ST_DEPTH_LOG2-1:0] alloc_i = st_index(addr_d);
  wire [TAG_W-1:0]        alloc_t = st_tagf(addr_d);

  wire [ST_DEPTH_LOG2-1:0] cmpl_i = st_index(outcome_addr);
  wire [TAG_W-1:0]        cmpl_t = st_tagf(outcome_addr);
  wire cmpl_hit = outcome_valid && st_valid[cmpl_i] && (st_tag[cmpl_i] == cmpl_t);

  logic                     sp_obs_valid;
  logic [N_PERSP*W_BITS-1:0] sp_obs_weights_i;
  logic [N_PERSP*IDX_W-1:0]  sp_obs_idx_i;
  logic signed [11:0]       sp_obs_sum_i;
  logic                     sp_obs_pred_i;
  logic                     sp_obs_low_conf_i;
  logic [2:0]               sp_obs_reuse_bucket_i;
  logic                     sp_obs_outcome_i;
  logic                     sp_obs_ready;

  assign sp_obs_valid          = cmpl_hit && (mode_q != M_OFF);
  assign sp_obs_weights_i      = st_weights[cmpl_i];
  assign sp_obs_idx_i          = st_idx[cmpl_i];
  assign sp_obs_sum_i          = st_sum[cmpl_i];
  assign sp_obs_pred_i         = st_pred[cmpl_i];
  assign sp_obs_low_conf_i     = st_lowconf[cmpl_i];
  assign sp_obs_reuse_bucket_i = st_bucket[cmpl_i];
  assign sp_obs_outcome_i      = outcome_i;

  wire drained = sp_obs_valid && sp_obs_ready;
  wire dropped = sp_obs_valid && !sp_obs_ready;

  integer si;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mode_q      <= M_OFF;
      warmup_ctr  <= '0;
      alloc_ctr   <= '0;
      st_alloc    <= '0; st_complete <= '0; st_evict <= '0; st_drop <= '0;
      tunes_applied <= '0;
      gates_applied <= {N_PERSP{8'h80}};
      theta_applied <= '0;
      epoch_applied <= '0;
      for (si = 0; si < ST_DEPTH; si = si + 1) st_valid[si] <= 1'b0;
    end else begin

      if (csr_mode_force_en) begin
        mode_q <= csr_mode_force;
      end else if (mode_q == M_OFF) begin
        mode_q <= M_OBS;
      end else if (mode_q == M_OBS && (sp_obs_seen >= WARMUP_OBS[15:0])) begin
        mode_q <= M_TUNELBL;
      end

      if (fp_out_valid) alloc_ctr <= alloc_ctr + 1'b1;

      if (do_alloc) begin

        if (st_valid[alloc_i] && !(cmpl_hit && (cmpl_i == alloc_i)))
          st_evict <= st_evict + 1'b1;
        st_tag[alloc_i]     <= alloc_t;
        st_weights[alloc_i] <= fp_obs_weights;
        st_idx[alloc_i]     <= fp_obs_idx;
        st_sum[alloc_i]     <= fp_out_sum;
        st_pred[alloc_i]    <= fp_out_pred;
        st_lowconf[alloc_i] <= fp_out_low_conf;
        st_bucket[alloc_i]  <= bucket_d;
        st_alloc            <= st_alloc + 1'b1;
      end

      if (cmpl_hit) begin
        st_complete <= st_complete + 1'b1;
        if (dropped) st_drop <= st_drop + 1'b1;
      end

      if (cmpl_hit && !(do_alloc && (alloc_i == cmpl_i)))
        st_valid[cmpl_i] <= 1'b0;
      if (do_alloc)
        st_valid[alloc_i] <= 1'b1;

      if (sp_tune_valid && (mode_q == M_TUNELBL)) begin
        gates_applied <= sp_gates_o;
        theta_applied <= sp_theta_o;
        epoch_applied <= sp_tune_epoch;
        tunes_applied <= tunes_applied + 1'b1;
      end

      if (flush_i) begin
        for (si = 0; si < ST_DEPTH; si = si + 1) st_valid[si] <= 1'b0;
      end
    end
  end

  wire fp_dbg_we = bd_we && (bd_target == 1'b0);
  wire sp_gw_we  = bd_we && (bd_target == 1'b1);

  logic                     sp_lbl_valid;
  logic                     sp_lbl_dir;
  logic [N_PERSP*IDX_W-1:0] sp_lbl_idx;

  logic lbl_enabled_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                       lbl_enabled_q <= 1'b0;
    else if (sp_obs_valid && sp_obs_ready)
                                      lbl_enabled_q <= (mode_q == M_TUNELBL);
  end

  wire fp_train_valid = sp_lbl_valid && lbl_enabled_q;
  wire fp_train_dir   = sp_lbl_dir;
  wire [N_PERSP*IDX_W-1:0] fp_train_idx = sp_lbl_idx;

  wire sp_lbl_ready   = fp_train_ready;

  wire [1:0] sp_mode = mode_q;

  assign obs_seen_o = sp_obs_seen;
  assign agree_cnt_o = sp_agree_cnt;

  // fast path
  fastpath_top #(.N_PERSP(N_PERSP), .IDX_W(IDX_W), .W_BITS(W_BITS)) u_fast (
    .clk           (clk),
    .rst_n         (rst_n),
    .req_valid     (req_valid),
    .pc_i          (pc_i),
    .addr_i        (addr_i),
    .set_idx_i     (set_idx_i),
    .pc_hist_i     (pc_hist_i),
    .reuse_bucket_i(reuse_bucket_i),
    .gates_i       (gates_applied),
    .theta_i       (theta_applied),
    .train_valid   (fp_train_valid),
    .train_dir     (fp_train_dir),
    .train_idx_i   (fp_train_idx),
    .dbg_we        (fp_dbg_we),
    .dbg_mask      (bd_fp_mask),
    .dbg_addr      (bd_addr),
    .dbg_wdata     (bd_wdata),
    .out_valid     (fp_out_valid),
    .out_sum       (fp_out_sum),
    .out_pred      (fp_out_pred),
    .out_low_conf  (fp_out_low_conf),
    .obs_idx       (fp_obs_idx),
    .obs_weights   (fp_obs_weights),
    .train_ready   (fp_train_ready),
    .upd_idle      (fp_upd_idle)
  );

  assign out_valid    = fp_out_valid;
  assign out_sum      = fp_out_sum;
  assign out_pred     = fp_out_pred;
  assign out_low_conf = fp_out_low_conf;

  // slow path
  slowpath_top #(.N_PERSP(N_PERSP), .IDX_W(IDX_W), .W_BITS(W_BITS)) u_slow (
    .clk               (clk),
    .rst_n             (rst_n),
    .obs_valid         (sp_obs_valid),
    .obs_ready         (sp_obs_ready),
    .obs_weights_i     (sp_obs_weights_i),
    .obs_idx_i         (sp_obs_idx_i),
    .obs_sum_i         (sp_obs_sum_i),
    .obs_pred_i        (sp_obs_pred_i),
    .obs_low_conf_i    (sp_obs_low_conf_i),
    .obs_reuse_bucket_i(sp_obs_reuse_bucket_i),
    .obs_outcome_i     (sp_obs_outcome_i),
    .tune_valid        (sp_tune_valid),
    .tune_ack          (1'b1),
    .gates_o           (sp_gates_o),
    .theta_o           (sp_theta_o),
    .tune_epoch        (sp_tune_epoch),
    .lbl_valid         (sp_lbl_valid),
    .lbl_ready         (sp_lbl_ready),
    .lbl_dir           (sp_lbl_dir),
    .lbl_idx           (sp_lbl_idx),
    .mode_i            (sp_mode),
    .flush_i           (flush_i),
    .gw_we             (sp_gw_we),
    .gw_bank           (bd_sp_bank),
    .gw_addr           (bd_addr),
    .gw_wdata          (bd_wdata),
    .busy              (sp_busy),
    .idle              (sp_idle),
    .obs_seen          (sp_obs_seen),
    .obs_dropped       (sp_obs_dropped),
    .agree_cnt         (sp_agree_cnt)
  );

`ifdef FORMAL_ASSERT

  always @(posedge clk) if (rst_n)
    assert (!(req_valid && fp_dbg_we));

  always @(posedge clk) if (rst_n)
    assert (!(sp_gw_we && sp_busy));
`endif

endmodule
`default_nettype wire
