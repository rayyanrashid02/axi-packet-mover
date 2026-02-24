`timescale 1ns/1ps

//------------------------------------------------------------------------------
// Testbench: fifo_async (dual-clock async FIFO, Gray pointers, 2FF sync)
//------------------------------------------------------------------------------
// Purpose:
//   - Self-checking verification under true CDC conditions:
//       * independent write/read clocks
//       * random bursts + stalls
//       * scoreboard compares all data in-order (no drop/dup/corruption)
//
// DUT semantics assumed (per our design choice):
//   - Write side: push occurs on wclk when (wr_en && !full)
//   - Read side : pop  occurs on rclk when (rd_en && !empty)
//   - Read data is REGISTERED: on pop, rd_data updates (NBA) to the popped word
//
// Simulator:
//   - iverilog -g2012
//------------------------------------------------------------------------------
module tb_fifo_async;

  localparam int WIDTH = 32;
  localparam int DEPTH = 16;   // power-of-2, >= 4

  //--------------------------------------------------------------------------
  // DUT I/O
  //--------------------------------------------------------------------------
  logic                 wclk, wrst_n;
  logic                 wr_en;
  logic [WIDTH-1:0]     wr_data;
  logic                 full;

  logic                 rclk, rrst_n;
  logic                 rd_en;
  logic [WIDTH-1:0]     rd_data;
  logic                 empty;

  fifo_async #(
    .WIDTH(WIDTH),
    .DEPTH(DEPTH)
  ) dut (
    .wclk   (wclk),
    .wrst_n (wrst_n),
    .wr_en  (wr_en),
    .wr_data(wr_data),
    .full   (full),

    .rclk   (rclk),
    .rrst_n (rrst_n),
    .rd_en  (rd_en),
    .rd_data(rd_data),
    .empty  (empty)
  );

  //--------------------------------------------------------------------------
  // Clocks: choose non-harmonically related periods + phase offset
  //   - wclk: 100 MHz (10 ns)
  //   - rclk: ~58.8 MHz (17 ns)
  //   - phase offset on rclk so posedges don't coincide with wclk posedges
  //--------------------------------------------------------------------------
  initial wclk = 1'b0;
  always  #5 wclk = ~wclk;

  initial begin
    rclk = 1'b0;
    #3;                 // phase offset
    forever #8.5 rclk = ~rclk;
  end

  //--------------------------------------------------------------------------
  // Waveforms
  //--------------------------------------------------------------------------
  initial begin
    $dumpfile("dumps/tb_fifo_async.vcd");
    $dumpvars(0, tb_fifo_async);
  end

  //--------------------------------------------------------------------------
  // Handshake detects
  //--------------------------------------------------------------------------
  wire push = wr_en && !full;
  wire pop  = rd_en && !empty;

  //--------------------------------------------------------------------------
  // Scoreboard model: expected queue
  //
  // IMPORTANT: Because clocks are asynchronous, avoid exact-cycle full/empty
  // equivalence checks vs queue size (flags are delayed by synchronizers).
  // Instead:
  //   - push adds to expected queue
  //   - pop checks rd_data equals expected front
  //--------------------------------------------------------------------------
  logic [WIDTH-1:0] exp_q[$];

  int push_count, pop_count;

  // Writer-side scoreboard: record pushes on wclk
  always @(posedge wclk) begin
    if (!wrst_n) begin
      // do nothing; we clear queue in global reset task
    end else begin
      if (push) begin
        exp_q.push_back(wr_data);
        push_count++;
      end
    end
  end

  // Reader-side compare is trickier due to registered read + NBA timing.
  // We:
  //   1) On rclk posedge, if pop occurs, latch expected value and set pending flag
  //   2) On rclk negedge (after NBA settle), compare rd_data to latched expected
  logic              pop_pending;
  logic [WIDTH-1:0]  exp_pending;

  always @(posedge rclk) begin
    if (!rrst_n) begin
      pop_pending <= 1'b0;
      exp_pending <= '0;
    end else begin
      if (pop) begin
        if (exp_q.size() == 0) begin
          $fatal(1, "ERROR: pop occurred but expected queue is empty!");
        end
        // Latch expected word that SHOULD appear on rd_data due to this pop
        exp_pending <= exp_q[0];
        pop_pending <= 1'b1;
      end
    end
  end

  always @(negedge rclk) begin
    if (rrst_n) begin
      if (pop_pending) begin
        // Now rd_data should have updated (registered read via NBA)
        if (rd_data !== exp_pending) begin
          $fatal(1, "ERROR: rd_data mismatch. got=%h exp=%h", rd_data, exp_pending);
        end
        void'(exp_q.pop_front());
        pop_count++;
        pop_pending <= 1'b0;
      end
    end
  end

  //--------------------------------------------------------------------------
  // TASKS: Infrastructure
  //--------------------------------------------------------------------------
  task automatic init_signals();
    begin
      wr_en   = 1'b0;
      wr_data = '0;
      rd_en   = 1'b0;
    end
  endtask

  task automatic clear_scoreboard();
    begin
      exp_q.delete();
      push_count  = 0;
      pop_count   = 0;
      pop_pending = 1'b0;
      exp_pending = '0;
    end
  endtask

  // Asynchronous resets asserted low; release cleanly in each clock domain
  task automatic apply_resets();
    begin
      wrst_n = 1'b0;
      rrst_n = 1'b0;

      // hold reset for a few cycles of each clock
      repeat (5) @(posedge wclk);
      repeat (5) @(posedge rclk);

      wrst_n = 1'b1;
      rrst_n = 1'b1;

      // let synchronizers settle a bit
      repeat (5) @(posedge wclk);
      repeat (5) @(posedge rclk);
    end
  endtask

  task automatic setup();
    begin
      init_signals();
      clear_scoreboard();
      apply_resets();
    end
  endtask

  // Drive write enable/data such that it's stable before wclk posedge
  task automatic drive_write(input logic en, input logic [WIDTH-1:0] data);
    begin
      @(negedge wclk);
      wr_en   = en;
      wr_data = data;
    end
  endtask

  // Drive read enable stable before rclk posedge
  task automatic drive_read(input logic en);
    begin
      @(negedge rclk);
      rd_en = en;
    end
  endtask

  task automatic stop_drivers();
    begin
      @(negedge wclk);
      wr_en   = 1'b0;
      wr_data = '0;
      @(negedge rclk);
      rd_en   = 1'b0;
    end
  endtask

  // Bounded wait until scoreboard queue drains to empty AND DUT asserts empty
  task automatic drain_to_empty();
    int timeout;
    begin
      timeout = 0;

      // Keep reading until expected queue empties
      while (exp_q.size() != 0 && timeout < 100000) begin
        drive_read(1'b1);
        @(posedge rclk);
        timeout++;
      end

      // Stop driving rd_en
      drive_read(1'b0);

      if (exp_q.size() != 0) begin
        $fatal(1, "ERROR: drain_to_empty timeout. exp_q.size=%0d", exp_q.size());
      end

      // Now wait for DUT empty to assert (CDC latency allowed)
      timeout = 0;
      while (!empty && timeout < 100000) begin
        @(posedge rclk);
        timeout++;
      end
      if (!empty) begin
        $fatal(1, "ERROR: empty did not assert after draining (CDC flag stuck?)");
      end
    end
  endtask

  task automatic final_checks(string testname);
    begin
      // Ensure pending pop completed
      repeat (2) @(posedge rclk);

      if (exp_q.size() != 0)
        $fatal(1, "ERROR(%s): expected queue not empty at end: %0d", testname, exp_q.size());

      if (push_count != pop_count)
        $fatal(1, "ERROR(%s): push_count(%0d) != pop_count(%0d)", testname, push_count, pop_count);

      $display("%s PASS: push_count=%0d pop_count=%0d", testname, push_count, pop_count);
    end
  endtask

  //--------------------------------------------------------------------------
  // TESTS
  //--------------------------------------------------------------------------

  // TB-3A: basic write then read under different clocks
  task automatic test_basic();
    begin
      $display("Running TB-3A: basic write/read...");

      // Write a small known sequence
      for (int i = 0; i < 20; i++) begin
        drive_write(1'b1, 32'hA000_0000 + i);
        @(posedge wclk);
      end
      drive_write(1'b0, '0);

      // Read until drained
      drain_to_empty();

      final_checks("TB-3A");
    end
  endtask

  // TB-3B: stress random push/pop with bursts and stalls
  task automatic test_random_stress();
    int unsigned seed;
    begin
      $display("Running TB-3B: random stress (bursts/stalls, async clocks)...");

      seed = 32'hC0FF_EE01;

      // Run for a while with independent random enables.
      // NOTE: We do not expect full/empty to match exp_q.size cycle-accurately
      // due to CDC latency, but the DUT must never corrupt ordering.
      for (int k = 0; k < 5000; k++) begin
        // Randomize write attempt
        if (($urandom(seed) % 100) < 60) begin
          drive_write(1'b1, $urandom(seed));
        end else begin
          drive_write(1'b0, '0);
        end

        // Randomize read attempt
        if (($urandom(seed) % 100) < 60) begin
          drive_read(1'b1);
        end else begin
          drive_read(1'b0);
        end

        // Advance some time: wait one edge of each clock (keeps both progressing)
        @(posedge wclk);
        @(posedge rclk);
      end

      // Stop random driving
      stop_drivers();

      // Drain any remaining data
      drain_to_empty();

      final_checks("TB-3B");
    end
  endtask

  // TB-3C: try to push into full / pop from empty (safety)
  // We don't "force" illegal behavior; we assert enables and ensure DUT blocks.
  task automatic test_full_empty_safety();
    int start_push;
    begin
      $display("Running TB-3C: full/empty safety...");

      // Fill aggressively until full asserts (allow CDC latency)
      start_push = push_count;
      while (!full) begin
        drive_write(1'b1, 32'hF000_0000 + (push_count-start_push));
        @(posedge wclk);
      end

      // Attempt additional writes for several cycles while full remains asserted
      for (int i = 0; i < 20; i++) begin
        drive_write(1'b1, 32'hDEAD_0000 + i);
        @(posedge wclk);
      end
      drive_write(1'b0, '0);

      // Now drain completely
      drain_to_empty();

      // Attempt additional reads while empty
      for (int j = 0; j < 20; j++) begin
        drive_read(1'b1);
        @(posedge rclk);
      end
      drive_read(1'b0);

      final_checks("TB-3C");
    end
  endtask

  //--------------------------------------------------------------------------
  // Top-level test sequence
  //--------------------------------------------------------------------------
  initial begin
    setup();

    test_basic();

    // Re-setup between tests for clean runs (recommended in CDC)
    setup();
    test_random_stress();

    setup();
    test_full_empty_safety();

    $finish;
  end

endmodule