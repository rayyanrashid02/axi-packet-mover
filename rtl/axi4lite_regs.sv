module axi4lite_regs #(
    parameter int ADDR_W = 8,    // enough for our small map (byte address)
    parameter int DATA_W = 32
)(
    input  logic                 clk,
    input  logic                 rst_n,

    // -------------------------
    // AXI4-Lite Write Address
    // -------------------------
    input  logic [ADDR_W-1:0]    s_axi_awaddr,
    input  logic                 s_axi_awvalid,
    output logic                 s_axi_awready,

    // -------------------------
    // AXI4-Lite Write Data
    // -------------------------
    input  logic [DATA_W-1:0]    s_axi_wdata,
    input  logic [DATA_W/8-1:0]  s_axi_wstrb,
    input  logic                 s_axi_wvalid,
    output logic                 s_axi_wready,

    // -------------------------
    // AXI4-Lite Write Response
    // -------------------------
    output logic [1:0]           s_axi_bresp,   // 2'b00 OKAY, 2'b10 SLVERR
    output logic                 s_axi_bvalid,
    input  logic                 s_axi_bready,

    // -------------------------
    // AXI4-Lite Read Address
    // -------------------------
    input  logic [ADDR_W-1:0]    s_axi_araddr,
    input  logic                 s_axi_arvalid,
    output logic                 s_axi_arready,

    // -------------------------
    // AXI4-Lite Read Data/Resp
    // -------------------------
    output logic [DATA_W-1:0]    s_axi_rdata,
    output logic [1:0]           s_axi_rresp,   // 2'b00 OKAY, 2'b10 SLVERR
    output logic                 s_axi_rvalid,
    input  logic                 s_axi_rready,

    // -------------------------
    // Control outputs to core
    // -------------------------
    output logic                 start_pulse,       // 1-cycle when CTRL.start written as 1
    output logic                 soft_reset_pulse,  // 1-cycle when CTRL.soft_reset written as 1
    output logic [31:0]          len_bytes,         // programmed length

    // -------------------------
    // Status inputs from core
    // -------------------------
    input  logic                 busy,
    input  logic                 done,              // recommend "sticky done" from ctrl, cleared by SW
    input  logic                 error,             // recommend sticky
    input  logic [31:0]          bytes_moved        // live or sticky count from ctrl
);

    // Internal latches to hold AW and W until both are valid, since AXI4-Lite allows them to arrive in either order
    logic aw_hold_valid;
    logic [ADDR_W-1:0] aw_hold_addr;

    logic w_hold_valid;
    logic [DATA_W-1:0] w_hold_data;
    logic [DATA_W/8-1:0] w_hold_strb;

    // Write response logic
    logic bvalid;
    logic [1:0] bresp_r;

    // Ready to accept aw or w if not holding one and not processing a write
    assign s_axi_awready = !aw_hold_valid && !bvalid;
    assign s_axi_wready = !w_hold_valid && !bvalid;

    // Handshake signals for AW, W, and Write processing
    wire aw_fire = s_axi_awvalid && s_axi_awready;
    wire w_fire  = s_axi_wvalid  && s_axi_wready;
    wire do_write = aw_hold_valid && w_hold_valid && !bvalid;

    assign s_axi_bvalid = bvalid;
    assign s_axi_bresp = bresp_r; // OKAY for now, could add error handling later

    // -------------------------
    // Helper function: apply WSTRB to 32-bit register
    // -------------------------
    function automatic [31:0] apply_wstrb32(
        input [31:0] oldv,
        input [31:0] newv,
        input [3:0]  strb
    );
        automatic [31:0] v;
        begin
            v = oldv;
            if (strb[0]) v[7:0]   = newv[7:0];
            if (strb[1]) v[15:8]  = newv[15:8];
            if (strb[2]) v[23:16] = newv[23:16];
            if (strb[3]) v[31:24] = newv[31:24];
            return v;
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_hold_valid <= 0;
            aw_hold_addr <= 0;
            w_hold_valid <= 0;
            w_hold_data <= 0;
            w_hold_strb <= 0;
            bvalid <= 0;
            bresp_r           <= 2'b00;

            start_pulse       <= 1'b0;
            soft_reset_pulse  <= 1'b0;
            len_bytes         <= 32'd0;
        end else begin
            // Default values for pulses
            start_pulse <= 1'b0;       // default no pulse
            soft_reset_pulse <= 1'b0;  // default no pulse

            // Hold AW until W arrives
            if (aw_fire) begin
                aw_hold_valid <= 1;
                aw_hold_addr <= s_axi_awaddr;
            end

            // Hold W until AW arrives
            if (w_fire) begin
                w_hold_valid <= 1;
                w_hold_data <= s_axi_wdata;
                w_hold_strb <= s_axi_wstrb;
            end

            // Commit write when both halves captured
            if (do_write) begin
                // Default response OKAY; change to SLVERR on bad addr
                bresp_r <= 2'b00;
                bvalid  <= 1'b1;

                unique case (aw_hold_addr)
                    8'h00: begin // CTRL
                        if (w_hold_data[0]) start_pulse      <= 1'b1;
                        if (w_hold_data[1]) soft_reset_pulse <= 1'b1;
                        // bits for CLR_DONE/CLR_ERR will come in Step 4.3
                    end
                    8'h04: begin // LEN
                        // Apply strobe to LEN register
                        len_bytes <= apply_wstrb32(len_bytes, w_hold_data[31:0], w_hold_strb);
                    end
                    default: begin
                        // Unmapped address => SLVERR (optional but nice)
                        bresp_r <= 2'b10;
                    end
                endcase

                // Clear holds after commit (so we can accept next write after response)
                aw_hold_valid <= 1'b0;
                w_hold_valid  <= 1'b0;
            end

            // Drop response when master accepts it
            if (bvalid && s_axi_bready) begin
                bvalid <= 1'b0;
            end

        end
    end

    // Local registers
    // logic [31:0] ctrl_reg;   // bit 0 = start, bit 1 = soft_reset
    // logic [31:0] len_reg;

    // // Write address handshake
    // logic aw_handshake = s_axi_awvalid && s_axi_awready;
    // assign s_axi_awready = !aw_handshake;  // accept one address at a time

    // // Write data handshake
    // logic w_handshake = s_axi_wvalid && s_axi_wready;
    // assign s_axi_wready = !w_handshake;  // accept one data beat at a time

    // // Write response logic
    // always_ff @(posedge clk or negedge rst_n) begin
    //     if (!rst_n) begin
    //         s_axi_bvalid <= 0;
    //         s_axi_bresp <= 2'b00; // OKAY
    //     end else if (aw_handshake && w_handshake) begin
    //         s_axi_bvalid <= 1;
    //         // Decode address and write to registers
    //         case (s_axi_awaddr)
    //             8'h00: ctrl_reg <= s_axi_wdata; // CTRL register
    //             8'h04: len_reg <= s_axi_wdata;  // LEN register
    //             default: ; // ignore writes to undefined addresses
    //         endcase
    //     end else if (s_axi_bvalid && s_axi_bready) begin
    //         s_axi_bvalid <= 0; // clear response after master acknowledges
    //     end
    // end

    // // Read address handshake
    // logic ar_handshake = s_axi_arvalid && s_axi_arready;
    // assign s_axi_arready = !ar_handshake;  // accept one read address at a time

    // // Read data/response logic
    // always_ff @(posedge clk or negedge rst_n) begin
    //     if (!rst_n) begin
    //         s_axi_rvalid <= 0;
    //         s_axi_rresp <= 2'b00; // OKAY
    //         s_axi_rdata <= 32'b0;
    //     end else if (ar_handshake) begin
    //         s_axi_rvalid <= 1;
    //         case (s_axi_araddr)
    //             8'h00: s_axi_rdata <= {30'b0, error, done}; // Status in CTRL reg readback
    //             8'h04: s_axi_rdata <= len_reg;              // LEN register readback
    //             default: begin
    //                 s_axi_rdata <= 32'b0;
    //                 s_axi_rresp <= 2'b10; // SLVERR for undefined addresses
    //             end
    //         endcase
    //     end else if (s_axi_rvalid && s_axi_rready) begin
    //         s_axi_rvalid <= 0; // clear valid after master acknowledges
    //         s_axi_rresp <= 2'b00; // reset response to OKAY for next transaction
    //     end
    // end

endmodule