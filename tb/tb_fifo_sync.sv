`timescale 1ns/1ps

//------------------------------------------------------------------------------
// Testbench: fifo_sync (single-clock FIFO, FWFT)
//------------------------------------------------------------------------------
// Purpose:
//   - Self-checking directed + randomized verification of fifo_sync
//   - Validates ordering, no drop/dup, full/empty behavior, pointer wrap
//   - Checks level matches expected occupancy
//
// Assumptions about DUT semantics (FWFT):
//   - rd_data reflects the next element whenever !empty (combinational read OK)
//   - pop occurs on rd_en && !empty
//   - push occurs on wr_en && !full
//
// Simulator:
//   - Icarus Verilog (iverilog -g2012)
//------------------------------------------------------------------------------
module tb_fifo_sync;

  localparam int WIDTH = 32;
  localparam int DEPTH = 16;   // power-of-2 (per project spec)

  //--------------------------------------------------------------------------
  // DUT I/O
  //--------------------------------------------------------------------------
  logic                 clk, rst_n;

  logic                 wr_en;
  logic [WIDTH-1:0]     wr_data;
  logic                 full;

  logic                 rd_en;
  logic [WIDTH-1:0]     rd_data;
  logic                 empty;

  logic [$clog2(DEPTH+1)-1:0] level;

  //--------------------------------------------------------------------------
  // DUT instance
  //--------------------------------------------------------------------------
  fifo_sync #(
    .WIDTH(WIDTH),
    .DEPTH(DEPTH)
  ) dut (
    .clk    (clk),
    .rst_n  (rst_n),
    .wr_en  (wr_en),
    .wr_data(wr_data),
    .full   (full),
    .rd_en  (rd_en),
    .rd_data(rd_data),
    .empty  (empty),
    .level  (level)
  );

  //--------------------------------------------------------------------------
  // Clock: 100 MHz (10 ns period)
  //--------------------------------------------------------------------------
  initial clk = 1'b0;
  always  #5 clk = ~clk;

  //--------------------------------------------------------------------------
  // Waveform dump
  //--------------------------------------------------------------------------
  initial begin
    $dumpfile("dumps/tb_fifo_sync.vcd");
    $dumpvars(0, tb_fifo_sync);
  end

  //--------------------------------------------------------------------------
  // Handshake detects (as in real FIFO spec)
  //--------------------------------------------------------------------------
  wire push = wr_en && !full;
  wire pop  = rd_en && !empty;

  //--------------------------------------------------------------------------
  // Scoreboard model: expected queue
  //
  // Push model when DUT accepts a write.
  // Pop/compare model when DUT accepts a read.
  // Also cross-check full/empty/level each cycle.
  //--------------------------------------------------------------------------
  logic [WIDTH-1:0] exp_q[$];
  int push_count, pop_count;

  // Sanity Check. Verify level/count matches expected queue occupancy.
  task automatic check_flags_level(string where);
    int exp_level;
    begin
      exp_level = exp_q.size();

      // level must match expected occupancy
      if (level !== exp_level[$bits(level)-1:0]) begin
        $fatal(1, "ERROR(%s): level mismatch. got=%0d exp=%0d",
               where, level, exp_level);
      end

      // empty/full must match occupancy
      if (empty !== (exp_level == 0)) begin
        $fatal(1, "ERROR(%s): empty mismatch. got=%b exp=%b (exp_level=%0d)",
               where, empty, (exp_level==0), exp_level);
      end
      if (full !== (exp_level == DEPTH)) begin
        $fatal(1, "ERROR(%s): full mismatch. got=%b exp=%b (exp_level=%0d)",
               where, full, (exp_level==DEPTH), exp_level);
      end
    end
  endtask

  always @(posedge clk) begin
    if (!rst_n) begin
      exp_q.delete();
      push_count <= 0;
      pop_count  <= 0;
    end else begin
      // Compare on pop (FWFT: rd_data should be current head during pop)
      if (pop) begin
        if (exp_q.size() == 0) begin
          $fatal(1, "ERROR: pop occurred but expected queue is empty!");
        end else begin
          logic [WIDTH-1:0] exp;
          exp = exp_q[0];
          if (rd_data !== exp) begin
            $fatal(1, "ERROR: rd_data mismatch on pop. got=%h exp=%h", rd_data, exp);
          end
          void'(exp_q.pop_front());
          pop_count++;
        end
      end

      // Record on push
      if (push) begin
        exp_q.push_back(wr_data);
        push_count++;
      end

    end
  end

  // Check flags/level after NBAs have settled (half-cycle later)
  always @(negedge clk) begin
    if (rst_n) begin
      check_flags_level("negedge");
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

  task automatic apply_reset(int unsigned cycles_low = 5);
    begin
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

  task automatic reset_counters();
    begin
      // Clear TB bookkeeping between tests (do not reset DUT here)
      exp_q.delete();
      push_count = 0;
      pop_count  = 0;

      // Ensure enables are deasserted
      wr_en   = 1'b0;
      wr_data = '0;
      rd_en   = 1'b0;

      repeat (2) @(posedge clk);
      check_flags_level("reset_counters");
    end
  endtask

  // Drive one-cycle push attempt (may or may not be accepted if full)
  task automatic try_push(input logic [WIDTH-1:0] val);
    begin
      // Drive stable before the sampling edge
      @(negedge clk);
      wr_data = val;
      wr_en   = 1'b1;

      @(posedge clk); // DUT samples here

      // Deassert after sampling edge
      @(negedge clk);
      wr_en   = 1'b0;
      wr_data = '0;
    end
  endtask


  // Drive one-cycle pop attempt (may or may not be accepted if empty)
  task automatic try_pop();
    begin
      @(negedge clk);
      rd_en = 1'b1;

      @(posedge clk);

      @(negedge clk);
      rd_en = 1'b0;
    end
  endtask


  // Drive push+pop in same cycle (important corner)
  task automatic try_push_pop_same_cycle(input logic [WIDTH-1:0] val);
    begin
      @(negedge clk);
      wr_data = val;
      wr_en   = 1'b1;
      rd_en   = 1'b1;

      @(posedge clk);

      @(negedge clk);
      wr_en   = 1'b0;
      rd_en   = 1'b0;
      wr_data = '0;
    end
  endtask


  task automatic drain_idle(int unsigned cycles = 5);
    begin
      wr_en = 1'b0;
      rd_en = 1'b0;
      repeat (cycles) @(posedge clk);
    end
  endtask

  task automatic final_checks(string testname);
    begin
      // settle for a few cycles
      drain_idle(5);

      // At end of directed tests we often expect empty; if you want otherwise, adjust per test.
      if (exp_q.size() != 0) begin
        $fatal(1, "ERROR(%s): expected queue not empty at end: %0d", testname, exp_q.size());
      end
      if (push_count != pop_count) begin
        // If FIFO ends empty, counts must match.
        $fatal(1, "ERROR(%s): push_count(%0d) != pop_count(%0d)", testname, push_count, pop_count);
      end

      $display("%s PASS: push_count=%0d pop_count=%0d", testname, push_count, pop_count);
    end
  endtask

  //--------------------------------------------------------------------------
  // TASKS: Tests
  //--------------------------------------------------------------------------

  // Test 2A: Fill to full, verify full asserts and further writes do not change state
  task automatic test_fill_to_full();
    begin
      $display("Running TB-2A: fill-to-full...");

      reset_counters();

      // Fill exactly DEPTH items
      for (int i = 0; i < DEPTH; i++) begin
        try_push(32'hF100_0000 + i);
      end

      // At this point expected queue size == DEPTH => full must be 1
      if (!full) $fatal(1, "ERROR(TB-2A): full not asserted after filling DEPTH entries");

      // Attempt extra pushes (should not be accepted)
      for (int j = 0; j < 5; j++) begin
        try_push(32'hDEAD_0000 + j);
      end

      // Still full; occupancy unchanged
      if (exp_q.size() != DEPTH) $fatal(1, "ERROR(TB-2A): occupancy changed after pushes to full");
      if (!full) $fatal(1, "ERROR(TB-2A): full deasserted unexpectedly");

      // Drain everything so final_checks can require empty
      for (int k = 0; k < DEPTH; k++) begin
        try_pop();
      end

      final_checks("TB-2A");
    end
  endtask

  // Test 2B: Drain to empty, verify empty asserts and further reads do not change state
  task automatic test_drain_to_empty();
    begin
      $display("Running TB-2B: drain-to-empty...");

      reset_counters();

      // Start with empty: empty must be 1
      if (!empty) $fatal(1, "ERROR(TB-2B): empty not asserted at start");

      // Attempt pops while empty (should not be accepted)
      for (int i = 0; i < 5; i++) begin
        try_pop();
      end
      if (!empty) $fatal(1, "ERROR(TB-2B): empty deasserted after popping empty FIFO");
      if (exp_q.size() != 0) $fatal(1, "ERROR(TB-2B): expected queue not empty unexpectedly");

      // Now push a few and drain
      for (int j = 0; j < 8; j++) begin
        try_push(32'hB200_0000 + j);
      end
      for (int k = 0; k < 8; k++) begin
        try_pop();
      end

      if (!empty) $fatal(1, "ERROR(TB-2B): empty not asserted after draining all entries");

      final_checks("TB-2B");
    end
  endtask

  // Test 2C: Simultaneous push+pop (keep FIFO mid-level and apply both enables)
  task automatic test_simultaneous_push_pop();
    begin
      $display("Running TB-2C: simultaneous push+pop...");

      reset_counters();

      // Preload to mid-level (e.g., 6 entries)
      for (int i = 0; i < 6; i++) begin
        try_push(32'hC300_0000 + i);
      end

      // Do several cycles of push+pop simultaneously
      for (int j = 0; j < 20; j++) begin
        try_push_pop_same_cycle(32'hC3AA_0000 + j);
      end

      // Drain everything
      while (!empty) begin
        try_pop();
      end

      final_checks("TB-2C");
    end
  endtask

  // Test 2D: Random push/pop with scoreboard
  task automatic test_random_push_pop();
    int unsigned seed;
    int timeout;
    begin
      $display("Running TB-2D: random push/pop...");

      reset_counters();

      seed = 32'h1BAD_F00D;

      // Randomly toggle wr_en/rd_en for many cycles
      for (int cyc = 0; cyc < 2000; cyc++) begin
        // Random enables (biased a bit so FIFO exercises both full/empty)
        wr_en   <= ($urandom(seed) % 100) < 55;
        rd_en   <= ($urandom(seed) % 100) < 55;
        wr_data <= $urandom(seed);
        @(posedge clk);

        // Deassert by default next cycle (keeps things simple/clean)
        wr_en   <= 1'b0;
        rd_en   <= 1'b0;
        wr_data <= '0;
      end

      // Drain to empty so we can do strict final checks
      timeout = 0;
      while (!empty && timeout < 2000) begin
        try_pop();
        timeout++;
      end
      if (!empty) $fatal(1, "ERROR(TB-2D): timeout draining FIFO at end");

      final_checks("TB-2D");
    end
  endtask

  //--------------------------------------------------------------------------
  // Top-level test sequence
  //--------------------------------------------------------------------------
  initial begin
    setup();

    test_fill_to_full();
    test_drain_to_empty();
    test_simultaneous_push_pop();
    test_random_push_pop();

    $finish;
  end

endmodule
