module fifo_async #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 16   // power-of-2, >= 4
)(
    // Write clock domain
    input  logic                 wclk,
    input  logic                 wrst_n,
    input  logic                 wr_en,
    input  logic [WIDTH-1:0]     wr_data,
    output logic                 full,

    // Read clock domain
    input  logic                 rclk,
    input  logic                 rrst_n,
    input  logic                 rd_en,
    output logic [WIDTH-1:0]     rd_data,
    output logic                 empty
);

    //--------------------------------------------------------------------------
    // Parameters / local constants
    //--------------------------------------------------------------------------
    localparam int ADDR_W = $clog2(DEPTH);
    localparam int PTR_W  = ADDR_W + 1; // extra MSB for wrap detection

    // Synthesis/simulation guardrails
    initial begin
        if (DEPTH < 4) $fatal(1, "fifo_async: DEPTH must be >= 4 (got %0d)", DEPTH);
        if ((DEPTH & (DEPTH-1)) != 0) $fatal(1, "fifo_async: DEPTH must be power-of-2 (got %0d)", DEPTH);
    end

    //--------------------------------------------------------------------------
    // FIFO storage
    //--------------------------------------------------------------------------
    logic [WIDTH-1:0] mem [0:DEPTH-1];

    //--------------------------------------------------------------------------
    // Write domain state
    //--------------------------------------------------------------------------
    logic [PTR_W-1:0] wptr_bin,  wptr_bin_next;
    logic [PTR_W-1:0] wptr_gray, wptr_gray_next;

    // Read pointer synchronized into write clock domain (Gray)
    logic [PTR_W-1:0] rptr_gray_w1, rptr_gray_w2;

    logic full_next;

    //--------------------------------------------------------------------------
    // Read domain state
    //--------------------------------------------------------------------------
    logic [PTR_W-1:0] rptr_bin,  rptr_bin_next;
    logic [PTR_W-1:0] rptr_gray, rptr_gray_next;

    // Write pointer synchronized into read clock domain (Gray)
    logic [PTR_W-1:0] wptr_gray_r1, wptr_gray_r2;

    logic empty_next;

    //--------------------------------------------------------------------------
    // Write and read enable logic (push/pop)
    //--------------------------------------------------------------------------
    logic push, pop;
    assign push = wr_en && !full;
    assign pop  = rd_en && !empty;

    //--------------------------------------------------------------------------
    // Pointer next-state + Gray conversion
    //--------------------------------------------------------------------------
    assign wptr_bin_next  = wptr_bin + (push ? 1'b1 : 1'b0);
    assign rptr_bin_next  = rptr_bin + (pop  ? 1'b1 : 1'b0);

    assign wptr_gray_next = (wptr_bin_next >> 1) ^ wptr_bin_next;
    assign rptr_gray_next = (rptr_bin_next >> 1) ^ rptr_bin_next;

    //--------------------------------------------------------------------------
    // Full/Empty detection (Gray-pointer)
    //--------------------------------------------------------------------------
    // Empty (in read domain): next read pointer equals synchronized write pointer
    assign empty_next = (rptr_gray_next == wptr_gray_r2);

    // Full (in write domain): next write pointer equals synchronized read pointer
    // with the two MSBs inverted (wrap check)
    assign full_next  = (wptr_gray_next ==
                        {~rptr_gray_w2[PTR_W-1:PTR_W-2], rptr_gray_w2[PTR_W-3:0]});

    //--------------------------------------------------------------------------
    // Write clock domain logic
    //--------------------------------------------------------------------------
    always_ff @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wptr_bin     <= '0;
            wptr_gray    <= '0;
            rptr_gray_w1 <= '0;
            rptr_gray_w2 <= '0;
            full         <= 1'b0;
        end else begin
            // CDC sync: bring read pointer Gray into write domain
            rptr_gray_w1 <= rptr_gray;
            rptr_gray_w2 <= rptr_gray_w1;

            // Write memory on successful push
            if (push) begin
                mem[wptr_bin[ADDR_W-1:0]] <= wr_data;
            end

            // Advance pointers + update full
            wptr_bin  <= wptr_bin_next;
            wptr_gray <= wptr_gray_next;
            full      <= full_next;
        end
    end

    //--------------------------------------------------------------------------
    // Read clock domain logic (registered read)
    //--------------------------------------------------------------------------
    always_ff @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rptr_bin     <= '0;
            rptr_gray    <= '0;
            wptr_gray_r1 <= '0;
            wptr_gray_r2 <= '0;
            empty        <= 1'b1;
            rd_data      <= '0;
        end else begin
            // CDC sync: bring write pointer Gray into read domain
            wptr_gray_r1 <= wptr_gray;
            wptr_gray_r2 <= wptr_gray_r1;

            // Registered read on successful pop
            if (pop) begin
                rd_data <= mem[rptr_bin[ADDR_W-1:0]];
            end

            // Advance pointers + update empty
            rptr_bin  <= rptr_bin_next;
            rptr_gray <= rptr_gray_next;
            empty     <= empty_next;
        end
    end

endmodule
