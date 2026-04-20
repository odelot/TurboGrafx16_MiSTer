//
// ddram.v
// Copyright (c) 2020 Sorgelig
//
// Modified: Added RetroAchievements toggle-based DDRAM channel
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. 
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
// ------------------------------------------
//


module ddram
(
input         DDRAM_CLK,

input         DDRAM_BUSY,
output  [7:0] DDRAM_BURSTCNT,
output [28:0] DDRAM_ADDR,
input  [63:0] DDRAM_DOUT,
input         DDRAM_DOUT_READY,
output        DDRAM_RD,
output [63:0] DDRAM_DIN,
output  [7:0] DDRAM_BE,
output        DDRAM_WE,

input         clkref,

input  [27:0] wraddr,
input  [15:0] din,
input         we,
output reg    we_rdy,
input         we_req,
output reg    we_ack,

input  [27:0] rdaddr,
output  [7:0] dout,
input         rd,
output reg    rd_rdy,

// --- RetroAchievements DDRAM channel (toggle-based) ---
input  [28:0] ra_wr_addr,
input  [63:0] ra_wr_din,
input   [7:0] ra_wr_be,
input         ra_wr_req,
output reg    ra_wr_ack,

input  [28:0] ra_rd_addr,
input         ra_rd_req,
output reg    ra_rd_ack,
output reg [63:0] ra_rd_dout
);

// RA active flag: when RA is processing, core is frozen
reg ra_active;
reg [2:0] ra_state;
localparam RA_ST_IDLE      = 3'd0;
localparam RA_ST_WRITE     = 3'd1;
localparam RA_ST_WRITE_W   = 3'd2;
localparam RA_ST_READ      = 3'd3;
localparam RA_ST_READ_W    = 3'd4;

// Track whether core has a pending read (cache issued DDRAM_RD)
reg core_read_pending;
wire cache_rd_out;  // cache's DDRAM_RD request

// Effective DDRAM signals - muxed between core and RA
wire [7:0]  core_burstcnt;
wire [28:0] core_addr;
wire [63:0] core_din;
wire [7:0]  core_be;
wire        core_we;
wire        core_busy = DDRAM_BUSY | ra_active;

assign DDRAM_BURSTCNT = ra_active ? 8'd1           : core_burstcnt;
assign DDRAM_ADDR     = ra_active ? ra_reg_addr     : core_addr;
assign DDRAM_DIN      = ra_active ? ra_reg_din      : core_din;
assign DDRAM_BE       = ra_active ? ra_reg_be       : core_be;
assign DDRAM_WE       = ra_active ? ra_reg_we       : core_we;
assign DDRAM_RD       = ra_active ? ra_reg_rd       : cache_rd_out;

// Core sees DOUT_READY only when RA is not active
wire core_dout_ready = ra_active ? 1'b0 : DDRAM_DOUT_READY;

// RA registered outputs for the mux
reg [28:0] ra_reg_addr;
reg [63:0] ra_reg_din;
reg  [7:0] ra_reg_be;
reg        ra_reg_we;
reg        ra_reg_rd;

// Core can start RA only when truly idle
wire ra_can_start = !core_read_pending && !DDRAM_BUSY && (state == 2'd0) && !start;

// Track core read pending
always @(posedge DDRAM_CLK) begin
if (cache_rd_out && !ra_active) core_read_pending <= 1;
if (DDRAM_DOUT_READY && !ra_active) core_read_pending <= 0;
if (ra_active) begin end // hold state while RA active
end

// --- RA state machine ---
always @(posedge DDRAM_CLK) begin
ra_reg_we <= 1'b0;
ra_reg_rd <= 1'b0;

case (ra_state)
RA_ST_IDLE: begin
ra_active <= 1'b0;
if (ra_can_start) begin
if (ra_wr_req != ra_wr_ack) begin
ra_active   <= 1'b1;
ra_reg_addr <= ra_wr_addr;
ra_reg_din  <= ra_wr_din;
ra_reg_be   <= ra_wr_be;
ra_reg_we   <= 1'b1;
ra_state    <= RA_ST_WRITE;
end
else if (ra_rd_req != ra_rd_ack) begin
ra_active   <= 1'b1;
ra_reg_addr <= ra_rd_addr;
ra_reg_be   <= 8'hFF;
ra_reg_rd   <= 1'b1;
ra_state    <= RA_ST_READ;
end
end
end

RA_ST_WRITE: begin
// WE was asserted for 1 cycle, wait 1 cycle for BUSY to assert
ra_state <= RA_ST_WRITE_W;
end

RA_ST_WRITE_W: begin
if (!DDRAM_BUSY) begin
ra_wr_ack <= ra_wr_req;
ra_active <= 1'b0;
ra_state  <= RA_ST_IDLE;
end
end

RA_ST_READ: begin
// RD was asserted for 1 cycle, wait for data
ra_state <= RA_ST_READ_W;
end

RA_ST_READ_W: begin
if (DDRAM_DOUT_READY) begin
ra_rd_dout <= DDRAM_DOUT;
ra_rd_ack  <= ra_rd_req;
ra_active  <= 1'b0;
ra_state   <= RA_ST_IDLE;
end
end

default: ra_state <= RA_ST_IDLE;
endcase
end

// --- Original core logic (unchanged except BUSY/DOUT_READY gating) ---

assign core_burstcnt = ram_burst;
assign core_be       = cache_rd_out ? 8'hFF : ({6'd0,~b,1'b1} << {ram_addr[2:1],ram_addr[0] & b});
assign core_addr     = {4'b0011, ram_addr[27:3]}; // RAM at 0x30000000
assign core_din      = ram_data;
assign core_we       = ram_write;

assign dout = data;

reg  [7:0] ram_burst;
reg [63:0] ram_data;
reg [27:0] ram_addr;
reg  [7:0] data;
reg        ram_write = 0;
reg        b;
reg        start;
reg  [1:0] state = 0;

reg [27:0] addr;

always @(posedge DDRAM_CLK) begin
reg        old_ref;
reg[127:0] ram_q;

old_ref <= clkref;
start <= ~old_ref & clkref;

if(start) begin
if(we) we_rdy <= 0;
else if(rd) rd_rdy <= 0;
end

ram_burst <= 1;
addr <= rdaddr;

if(!core_busy) begin
ram_write <= 0;
case(state)
0: begin
we_rdy <= 1;
rd_rdy <= 1;
cache_cs <= 0;
if(we_ack != we_req) begin
we_ack     <= we_req;
ram_data   <= {4{din}};
ram_addr   <= wraddr;
ram_write  <= 1;
b          <= 0;
end
else if(start) begin
if(we) begin
we_rdy    <= 0;
ram_data  <= {8{din[7:0]}};
ram_addr  <= addr;
ram_write <= 1;
b         <= 1;
cache_cs  <= 1;
cache_we  <= 1;
state     <= 1;
end
else if(rd) begin
ram_addr  <= addr;
rd_rdy    <= 0;
cache_cs  <= 1;
cache_we  <= 0;
state     <= 2;
end
end
end

1: if(cache_wrack) begin
cache_cs <= 0;
we_rdy <= 1;
state  <= 0;
end

2: if(cache_rdack) begin
cache_cs <= 0;
data <= ram_addr[0] ? cache_do[15:8] : cache_do[7:0];
rd_rdy <= 1;
state  <= 0;
end
endcase
end
end

wire [15:0] cache_do;
wire        cache_rdack;
wire        cache_wrack;
reg         cache_cs;
reg         cache_we;

cache_2way cache
(
.clk(DDRAM_CLK),
.rst(we_ack != we_req),

.cache_enable(1),

.cpu_cs(cache_cs),
.cpu_adr(addr[27:1]),
.cpu_bs({addr[0],~addr[0]}),
.cpu_we(cache_we),
.cpu_rd(~cache_we),
.cpu_dat_w(ram_data[15:0]),
.cpu_dat_r(cache_do),
.cpu_ack(cache_rdack),
.wb_en(cache_wrack),

.mem_dat_r(DDRAM_DOUT),
.mem_read_req(cache_rd_out),
.mem_read_ack(core_dout_ready)
);

endmodule
