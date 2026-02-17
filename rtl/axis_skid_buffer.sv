module axis_skid_buffer #(
    parameter int DATA_W = 32
)(
    input  logic                 clk,
    input  logic                 rst_n,

    // Slave side (input stream)
    input  logic                 s_valid,
    output logic                 s_ready,
    input  logic [DATA_W-1:0]    s_data,

    // Master side (output stream)
    output logic                 m_valid,
    input  logic                 m_ready,
    output logic [DATA_W-1:0]    m_data
);

    logic buf_valid;
    logic [DATA_W-1:0] buf_data;

  //--------------------------------------------------------------------------
  // Combinational outputs
  //
  // If buffer has data, drive it.
  // Else pass through input.
  //--------------------------------------------------------------------------
    always_comb begin
        if (buf_valid) begin
            m_valid = 1'b1;
            m_data = buf_data;
        end else begin
            m_valid = s_valid;
            m_data = s_data;
        end
    end

  //--------------------------------------------------------------------------
  // Upstream ready:
  // - If buffer is holding data, we cannot accept new input (1-deep).
  // - If buffer is empty, we can accept input when downstream can accept
  //   *this cycle* OR when we'll be buffering? (We only have 1 slot, so if
  //   downstream isn't ready, we must not accept a new beat unless we can
  //   store it. We can store at most 1 beat, which is exactly the current beat,
  //   so accepting when m_ready=0 is OK only if buffer is empty.
  //
  // Practically:
  //   s_ready = !buf_valid && (m_ready || !s_valid ? 1 : 1)
  // But we must be careful: if buffer empty, we *may* accept a beat even when
  // m_ready=0, because we can capture it into the buffer.
  //
  // So:
  //   s_ready = !buf_valid;  (we can always take 1 beat into either downstream
  //                           (if m_ready) or buffer (if !m_ready))
  //
  // This is the defining behavior of a skid buffer.
  //--------------------------------------------------------------------------
    assign s_ready = ~buf_valid;
    wire out_fire = m_valid && m_ready;
    wire in_fire = s_valid && s_ready;

  //--------------------------------------------------------------------------
  // Sequential: capture / release buffer
  //--------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        // Reset Buffers
        if (!rst_n) begin
            buf_valid <= 1'b0;
            buf_data <= '0;
        end else begin
            // If buffer holds data
            if (buf_valid) begin
                // If downstream accepting data, buffer sends it
                if (out_fire) begin
                    buf_valid <= 0;
                end
                // Else it does nothing (buffer holds data)
            end else begin
                // If downstream signals stall but upstream sent data
                if (!m_ready && in_fire) begin
                    // Move it into buffer
                    buf_valid <= 1'b1;
                    buf_data <= s_data;
                end
            end
        end
    end

endmodule
