module fifo_sync #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 16   // power-of-2
)(
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 wr_en,
    input  logic [WIDTH-1:0]     wr_data,
    output logic                 full,

    input  logic                 rd_en,
    output logic [WIDTH-1:0]     rd_data,
    output logic                 empty,

    output logic [$clog2(DEPTH+1)-1:0] level
);
    localparam int PTR_W = $clog2(DEPTH);

    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [PTR_W-1:0] wr_ptr, rd_ptr;
    logic [$clog2(DEPTH+1)-1:0] count;

    logic push, pop;

    assign push = wr_en && !full;
    assign pop  = rd_en && !empty;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            count <= 0;
        end else begin
            if (push) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr <= wr_ptr + 1;
            end

            if (pop) begin
                rd_ptr <= rd_ptr + 1;
            end

            case ({push, pop})
                2'b10: count <= count + 1;
                2'b01: count <= count - 1;
                default: count <= count;
            endcase
        end
    end

    assign rd_data = mem[rd_ptr];
    assign full = (count == DEPTH);
    assign empty = (count == 0);
    assign level = count;

endmodule
