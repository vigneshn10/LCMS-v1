`ifndef FAKERAM7_256X8_V
`define FAKERAM7_256X8_V

module fakeram7_256x8
(
   rd_out,
   addr_in,
   we_in,
   wd_in,
   clk,
   ce_in
);
   parameter BITS = 8;
   parameter WORD_DEPTH = 256;
   parameter ADDR_WIDTH = 8;
   parameter corrupt_mem_on_X_p = 1;

   output reg [BITS-1:0]    rd_out;
   input  [ADDR_WIDTH-1:0]  addr_in;
   input                    we_in;
   input  [BITS-1:0]        wd_in;
   input                    clk;
   input                    ce_in;

   reg    [BITS-1:0]        mem [0:WORD_DEPTH-1];

   integer j;

   always @(posedge clk)
   begin
      if (ce_in)
      begin

         if (corrupt_mem_on_X_p &&
             ((^we_in === 1'bx) || (^addr_in === 1'bx))
            )
         begin

            for (j = 0; j < WORD_DEPTH; j = j + 1)
               mem[j] <= 'x;
            $display("warning: ce_in=1, we_in is %b, addr_in = %x in fakeram7_256x8", we_in, addr_in);
         end
         else if (we_in)
         begin
            mem[addr_in] <= wd_in;
         end

         rd_out <= mem[addr_in];
      end
      else
      begin

         rd_out <= 'x;
      end
   end

`ifdef ENABLE_SPECIFY

   reg notifier;
   specify

      (posedge clk *> rd_out) = (0, 0);

      $width     (posedge clk,            0, 0, notifier);
      $width     (negedge clk,            0, 0, notifier);
      $period    (posedge clk,            0,    notifier);
      $setuphold (posedge clk, we_in,     0, 0, notifier);
      $setuphold (posedge clk, ce_in,     0, 0, notifier);
      $setuphold (posedge clk, addr_in,   0, 0, notifier);
      $setuphold (posedge clk, wd_in,     0, 0, notifier);
   endspecify
`endif

endmodule

`endif 
