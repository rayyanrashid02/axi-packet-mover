`timescale 1ns/1ps

//------------------------------------------------------------------------------
// Testbench: axis_skid_buffer
//
// Purpose:
//   - Self-checking simulation TB for 1-deep AXI-Stream-style skid buffer
//   - Verifies: no drop, no duplication, ordering preserved under backpressure
//
// Method:
//   - Scoreboard queue tracks all accepted input beats (s_valid && s_ready)
//   - On each accepted output beat (m_valid && m_ready), pop and compare
//
// Notes:
//   - This is a "module-level" directed+random TB (not UVM).
//   - Intended to run under iverilog (-g2012).
//------------------------------------------------------------------------------
module tb_axis_skid_buffer;

  localparam int DATA_W = 32;

  //--------------------------------------------------------------------------
  // DUT interface signals
  //--------------------------------------------------------------------------
  logic                 clk, rst_n;

  logic                 s_valid;
  logic                 s_ready;
  logic [DATA_W-1:0]    s_data;

  logic                 m_valid;
  logic                 m_ready;
  logic [DATA_W-1:0]    m_data;

  //--------------------------------------------------------------------------
  // DUT instantiation
  //--------------------------------------------------------------------------
  axis_skid_buffer #(.DATA_W(DATA_W)) dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .s_valid (s_valid),
    .s_ready (s_ready),
    .s_data  (s_data),
    .m_valid (m_valid),
    .m_ready (m_ready),
    .m_data  (m_data)
  );

  //--------------------------------------------------------------------------
  // Clock generation: 100 MHz (10 ns period)
  //--------------------------------------------------------------------------
  initial clk = 1'b0;
  always  #5 clk = ~clk;

  //--------------------------------------------------------------------------
  // Waveform dump
  //--------------------------------------------------------------------------
  initial begin
    $dumpfile("dumps/tb_axis_skid_buffer.vcd");
    $dumpvars(0, tb_axis_skid_buffer);
  end

  //--------------------------------------------------------------------------
  // Common handshake helpers
  //--------------------------------------------------------------------------
  wire in_fire  = s_valid && s_ready;
  wire out_fire = m_valid && m_ready;

  //--------------------------------------------------------------------------
  // Scoreboard: expected queue
  //
  // Push when input is accepted (in_fire).
  // Pop+compare when output is accepted (out_fire).
  // This proves: no drop, no duplication, order preserved.
  //--------------------------------------------------------------------------
  logic [DATA_W-1:0] exp_q[$];

  always @(posedge clk) begin
    if (!rst_n) begin
      exp_q.delete();
    end else begin
      if (in_fire) begin
        exp_q.push_back(s_data);
      end

      if (out_fire) begin
        if (exp_q.size() == 0) begin
          $fatal(1, "ERROR: output fired but expected queue is empty!");
        end else begin
          logic [DATA_W-1:0] exp;
          exp = exp_q.pop_front();
          if (m_data !== exp) begin
            $fatal(1, "ERROR: m_data mismatch. got=%h exp=%h", m_data, exp);
          end
        end
      end
    end
  end

  //--------------------------------------------------------------------------
  // Simple counters for sanity checks / debug
  //--------------------------------------------------------------------------
  int in_count, out_count;

  always @(posedge clk) begin
    if (!rst_n) begin
      in_count  <= 0;
      out_count <= 0;
    end else begin
      if (in_fire)  in_count++;
      if (out_fire) out_count++;
    end
  end

  //--------------------------------------------------------------------------
  // Checker: hold stable data when downstream not ready
  //--------------------------------------------------------------------------
  // When the DUT is presenting valid data and downstream is not ready,
  // AXI requires the presented data to remain stable.
  logic [DATA_W-1:0] hold_data;
  logic              hold_active;

  always @(posedge clk) begin
    if (!rst_n) begin
      hold_active <= 1'b0;
      hold_data   <= '0;
    end else begin
      if (m_valid && !m_ready) begin
        if (!hold_active) begin
          hold_active <= 1'b1;
          hold_data   <= m_data;
        end else begin
          if (m_data !== hold_data) begin
            $fatal(1, "ERROR: m_data changed while m_valid=1 && m_ready=0. prev=%h now=%h",
                   hold_data, m_data);
          end
        end
      end else begin
        hold_active <= 1'b0;
      end
    end
  end

  //--------------------------------------------------------------------------
  // TASKS: Infrastructure
  //--------------------------------------------------------------------------
  task automatic init_signals();
    begin
      // Drive known defaults before/around reset
      s_valid = 1'b0;
      s_data  = '0;
      m_ready = 1'b0;
    end
  endtask

  task automatic apply_reset(int unsigned cycles_low = 5);
    begin
      // Asynchronous reset asserted low; release on a clock edge for cleanliness
      rst_n = 1'b0;
      repeat (cycles_low) @(posedge clk);
      rst_n = 1'b1;
      @(posedge clk);
    end
  endtask

  task automatic setup();
    begin
      init_signals();
      apply_reset(5);
    end
  endtask

  // Drive exactly one beat as a 1-cycle valid pulse.
  // Waits until DUT can accept (s_ready==1), then presents val for one cycle.
  task automatic drive_beat(input logic [DATA_W-1:0] val);
    begin
      // Wait until DUT indicates it can accept a beat
      while (!s_ready) @(posedge clk);

      s_data  <= val;
      s_valid <= 1'b1;
      @(posedge clk);

      // Deassert after one cycle (single-beat pulse)
      s_valid <= 1'b0;
      s_data  <= '0;
    end
  endtask

  task automatic drain_pipeline(int unsigned cycles = 10);
    begin
      repeat (cycles) @(posedge clk);
    end
  endtask

  task automatic final_checks(string testname);
    begin
      // Let any buffered data flush through before checking emptiness
      drain_pipeline(10);

      if (exp_q.size() != 0)
        $fatal(1, "ERROR(%s): expected queue not empty at end: %0d", testname, exp_q.size());

      if (in_count != out_count)
        $fatal(1, "ERROR(%s): in_count(%0d) != out_count(%0d)", testname, in_count, out_count);

      $display("%s PASS: in_count=%0d out_count=%0d", testname, in_count, out_count);
    end
  endtask

  task automatic reset_counters();
    begin
      // Clear TB bookkeeping so each test is self-contained.
      exp_q.delete();
      in_count  = 0;
      out_count = 0;

      // Optional: settle for a couple cycles
      repeat (2) @(posedge clk);
    end
  endtask


  //--------------------------------------------------------------------------
  // TASKS: Tests
  //--------------------------------------------------------------------------
  task automatic test_pass_through();
    begin
      $display("Running TB-3: always-ready pass-through...");

      reset_counters();

      // Downstream always ready
      m_ready = 1'b1;

      // A few idle cycles
      repeat (2) @(posedge clk);

      // 20 beats continuous
      for (int i = 0; i < 20; i++) begin
        drive_beat(32'hA000_0000 + i);
      end

      // Bubbles between beats
      repeat (3) @(posedge clk);
      for (int j = 0; j < 20; j++) begin
        drive_beat(32'hB000_0000 + j);
        repeat (j % 3) @(posedge clk);
      end

      final_checks("TB-3");
    end
  endtask

  task automatic test_hold_stall();
    logic [DATA_W-1:0] first;
    begin
      $display("Running TB-4: multi-cycle stall hold...");

      reset_counters();

      // Force stall
      m_ready = 1'b0;
      repeat (2) @(posedge clk);

      // Send exactly one beat while stalled: should be accepted and buffered
      first = 32'hC000_0001;
      drive_beat(first);

      // While stalled, the DUT must:
      // - hold m_valid high
      // - hold m_data constant
      // - deassert s_ready (can't accept more)
      repeat (8) begin
        @(posedge clk);
        if (m_valid !== 1'b1) $fatal(1, "ERROR: expected m_valid=1 during stall");
        if (s_ready !== 1'b0) $fatal(1, "ERROR: expected s_ready=0 (backpressure) during stall");
      end

      // Release downstream
      m_ready = 1'b1;
            
      // Wait until the buffered beat is actually consumed
      // (i.e., an output transfer occurs)
      while (!out_fire) @(posedge clk);

      // After releasing, allow drain and then check scoreboard/counters
      final_checks("TB-4");
    end
  endtask

  task automatic test_skid_corner();
    int timeout;
    begin
      $display("Running TB-5: single-cycle stall (skid corner)...");

      reset_counters();

      // We'll keep upstream attempting to send a run of beats.
      // For simplicity (since drive_beat is 1-cycle pulse), we send beats one-by-one.
      // The key is the ready pattern around one beat.
      //
      // Ready pattern: 1,1,0,1,1...
      m_ready = 1'b1;
      repeat (2) @(posedge clk);

      // Send D0, D1 with ready=1
      drive_beat(32'hD000_0000);
      drive_beat(32'hD000_0001);

      // Single-cycle stall: deassert ready for exactly one cycle
      @(negedge clk);
      m_ready = 1'b0;
      @(posedge clk); // stall cycle sampled here

      // While stalled, attempt to send next beat (should be accepted+buffered if buffer empty)
      // Note: drive_beat waits for s_ready, and s_ready should still be 1 if buffer was empty.
      // This beat is the one we expect to get buffered.
      drive_beat(32'hD000_0002);

      // Immediately re-assert ready (stall lasted exactly 1 cycle)
      @(negedge clk);
      m_ready = 1'b1;

      // Now send a few more beats; buffer should drain then pass-through continues.
      drive_beat(32'hD000_0003);
      drive_beat(32'hD000_0004);
      drive_beat(32'hD000_0005);

      // Bounded wait for queue to drain
      timeout = 0;
      while (exp_q.size() != 0 && timeout < 200) begin
        @(posedge clk);
        timeout++;
      end
      if (exp_q.size() != 0)
        $fatal(1, "ERROR(TB-5): timeout waiting for queue to drain (size=%0d)", exp_q.size());

      final_checks("TB-5");
    end
  endtask



  //--------------------------------------------------------------------------
  // Top-level test sequence
  //--------------------------------------------------------------------------
  initial begin
    setup();

    // Directed tests (start with simplest)
    test_pass_through();
    test_hold_stall();
    test_skid_corner();

    // Future:
    // test_random_stress();

    $finish;
  end

endmodule
