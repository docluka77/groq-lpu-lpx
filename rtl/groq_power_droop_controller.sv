// =============================================================================
// Module: groq_power_droop_controller
// Description: Stage 19 Deterministic L*di/dt Voltage Droop Mitigation &
//              Thermal Controller IP for Groq LPU / Groq 3 LPX.
//              Models slice-level instantaneous current demand, compiler-hinted
//              pre-warm ramp-up & post-burst ramp-down dummy bleeder control,
//              discrete-time RLC supply droop estimator, and thermal protection.
// Reference:   Abts et al., ISCA 2020 (Deterministic L*di/dt current control)
// =============================================================================
`default_nettype none

module groq_power_droop_controller (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                enable_i,

    // Spatial Slice Activity & Sparsity Telemetry
    // [0]=NIM, [1]=MEM_W, [2]=SXM, [3]=VXM, [4]=MXM_W, [5]=ICU, [6]=MXM_E, [7]=MEM_E
    input  wire  [7:0]         slice_active_i,
    input  wire  [5:0]         mxm_zero_skip_cnt_i,

    // ICU Compiler-Scheduled Lookahead Pre-Warm Hint & Slew-Rate Config
    input  wire                prewarm_hint_i,
    input  wire  [7:0]         prewarm_target_level_i,
    input  wire  [7:0]         max_didt_step_i,

    // Supply Voltage & Droop Protection Thresholds (mV)
    input  wire  [11:0]        vdd_nominal_mv_i,
    input  wire  [11:0]        droop_emerg_thresh_mv_i,

    // Active Bleeder Control & Power/Thermal Telemetry Outputs
    output logic [7:0]         raw_demand_o,
    output logic [7:0]         eff_current_o,
    output logic [7:0]         dummy_bleed_current_o,
    output logic [7:0]         dummy_bleed_mask_o,
    output logic signed [8:0]  didt_signed_o,
    output logic [11:0]        vdd_est_mv_o,
    output logic [7:0]         thermal_temp_c_o,
    output logic               emerg_throttle_o,
    output logic [15:0]        droop_mitigated_events_o
);

    // -------------------------------------------------------------------------
    // 1. Instantaneous Functional Slice Current Demand Model (Range: 0..240)
    // -------------------------------------------------------------------------
    logic [5:0] mxm_skip_clamped_c;
    logic [7:0] mxm_unit_curr_c;
    logic [7:0] mxm_w_curr_c, mxm_e_curr_c;
    logic [7:0] vxm_curr_c, sxm_curr_c;
    logic [7:0] mem_w_curr_c, mem_e_curr_c;
    logic [7:0] nim_curr_c, icu_curr_c;
    logic [7:0] raw_demand_c;

    always_comb begin
        mxm_skip_clamped_c = (mxm_zero_skip_cnt_i > 6'd32) ? 6'd32 : mxm_zero_skip_cnt_i;
        mxm_unit_curr_c    = 8'd64 - {2'd0, mxm_skip_clamped_c};

        nim_curr_c   = slice_active_i[0] ? 8'd12           : 8'd0;
        mem_w_curr_c = slice_active_i[1] ? 8'd20           : 8'd0;
        sxm_curr_c   = slice_active_i[2] ? 8'd24           : 8'd0;
        vxm_curr_c   = slice_active_i[3] ? 8'd24           : 8'd0;
        mxm_w_curr_c = slice_active_i[4] ? mxm_unit_curr_c : 8'd0;
        icu_curr_c   = slice_active_i[5] ? 8'd12           : 8'd0;
        mxm_e_curr_c = slice_active_i[6] ? mxm_unit_curr_c : 8'd0;
        mem_e_curr_c = slice_active_i[7] ? 8'd20           : 8'd0;

        raw_demand_c = nim_curr_c + mem_w_curr_c + sxm_curr_c + vxm_curr_c +
                       mxm_w_curr_c + icu_curr_c + mxm_e_curr_c + mem_e_curr_c;
        raw_demand_o = raw_demand_c;
    end

    // -------------------------------------------------------------------------
    // 2. Deterministic Current Slew-Rate Limiter & Dummy Bleeder Controller
    // -------------------------------------------------------------------------
    logic [7:0] eff_current_q, eff_current_next;
    logic [7:0] ramp_down_floor_c;
    logic [8:0] step_up_sum_c;
    logic [7:0] prewarm_step_up_c;
    logic [7:0] bleed_target_c;

    always_comb begin
        ramp_down_floor_c = (eff_current_q > max_didt_step_i) ?
                            (eff_current_q - max_didt_step_i) : 8'd0;
        step_up_sum_c     = {1'b0, eff_current_q} + {1'b0, max_didt_step_i};
        prewarm_step_up_c = (step_up_sum_c >= {1'b0, prewarm_target_level_i}) ?
                            prewarm_target_level_i : step_up_sum_c[7:0];

        bleed_target_c = ramp_down_floor_c;
        if (prewarm_hint_i && (raw_demand_c < prewarm_target_level_i)) begin
            if (prewarm_step_up_c > bleed_target_c) begin
                bleed_target_c = prewarm_step_up_c;
            end
        end

        if (!enable_i) begin
            eff_current_next      = raw_demand_c;
            dummy_bleed_current_o = 8'd0;
        end else if (raw_demand_c < bleed_target_c) begin
            eff_current_next      = bleed_target_c;
            dummy_bleed_current_o = bleed_target_c - raw_demand_c;
        end else begin
            eff_current_next      = raw_demand_c;
            dummy_bleed_current_o = 8'd0;
        end

        for (int k = 0; k < 8; k++) begin
            dummy_bleed_mask_o[k] = (dummy_bleed_current_o > 8'(k * 16));
        end
    end

    // -------------------------------------------------------------------------
    // 3. Discrete-Time RLC Supply Voltage & Thermal Estimator
    // -------------------------------------------------------------------------
    logic [7:0]  abs_didt_c;
    logic [11:0] ir_drop_mv_c, ind_drop_mv_c, total_drop_mv_c;
    logic [7:0]  temp_eq_c;
    logic [2:0]  therm_tick_q;
    wire         _unused_ok = &{1'b0, abs_didt_c[0]};

    always_comb begin
        didt_signed_o   = ({1'b0, eff_current_next}) - ({1'b0, eff_current_q});
        abs_didt_c      = (eff_current_next >= eff_current_q) ?
                          (eff_current_next - eff_current_q) :
                          (eff_current_q - eff_current_next);
        ir_drop_mv_c    = {6'd0, eff_current_next[7:2]};
        ind_drop_mv_c   = {5'd0, abs_didt_c[7:1]};
        total_drop_mv_c = ir_drop_mv_c + ind_drop_mv_c;

        vdd_est_mv_o = (vdd_nominal_mv_i > total_drop_mv_c) ?
                       (vdd_nominal_mv_i - total_drop_mv_c) : 12'd0;

        temp_eq_c        = 8'd45 + {2'd0, eff_current_q[7:2]};
        emerg_throttle_o = (vdd_est_mv_o < droop_emerg_thresh_mv_i) ||
                           (thermal_temp_c_o >= 8'd105);
        eff_current_o    = eff_current_q;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eff_current_q            <= 8'd0;
            thermal_temp_c_o         <= 8'd45;
            therm_tick_q             <= 3'd0;
            droop_mitigated_events_o <= 16'd0;
        end else begin
            eff_current_q <= eff_current_next;
            if (enable_i) begin
                therm_tick_q <= therm_tick_q + 3'd1;
                if (therm_tick_q == 3'd7) begin
                    if (thermal_temp_c_o < temp_eq_c)
                        thermal_temp_c_o <= thermal_temp_c_o + 8'd1;
                    else if (thermal_temp_c_o > temp_eq_c)
                        thermal_temp_c_o <= thermal_temp_c_o - 8'd1;
                end
                if ((dummy_bleed_current_o != 8'd0) && (droop_mitigated_events_o != 16'hFFFF)) begin
                    droop_mitigated_events_o <= droop_mitigated_events_o + 16'd1;
                end
            end
        end
    end

`ifdef FORMAL
    always_comb begin
        // 1. Functional demand upper bound (2*64 + 2*24 + 2*20 + 2*12 = 240)
        assert(raw_demand_o <= 8'd240);
        // 2. Ramp-down di/dt slew-rate bound & bleeder complement invariant
        if (enable_i) begin
            if (eff_current_q >= eff_current_next) begin
                assert((eff_current_q - eff_current_next) <= max_didt_step_i);
            end
            assert(eff_current_next == (raw_demand_c + dummy_bleed_current_o));
        end
        // 3. Pre-warmed ramp-up slew-rate bound
        if (enable_i && prewarm_hint_i && (raw_demand_c <= eff_current_q) &&
            (eff_current_q < prewarm_target_level_i)) begin
            assert(eff_current_next >= eff_current_q);
            assert((eff_current_next - eff_current_q) <= max_didt_step_i);
        end
        // 4. Emergency throttle exactness
        assert(emerg_throttle_o == ((vdd_est_mv_o < droop_emerg_thresh_mv_i) ||
                                    (thermal_temp_c_o >= 8'd105)));
    end
`endif

endmodule
`default_nettype wire
