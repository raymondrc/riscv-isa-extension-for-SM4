`ifndef SCR1_AHB_SVH
`define SCR1_AHB_SVH
/// Copyright by Syntacore LLC © 2016-2018. See LICENSE for details
/// @file       <scr1_ahb.svh>
/// @brief      AHB header file
///

`include "scr1_arch_description.svh"

parameter SCR1_AHB_WIDTH  = 32;

// Encoding for HTRANS signal
parameter logic [1:0] SCR1_HTRANS_IDLE   = 2'b00;
parameter logic [1:0] SCR1_HTRANS_NONSEQ = 2'b10;
parameter logic [1:0] SCR1_HTRANS_ERR    = 'x;

// Encoding for HBURST signal
parameter logic [2:0] SCR1_HBURST_SINGLE = 3'b000;
parameter logic [2:0] SCR1_HBURST_ERR    = 'x;

// Encoding for HSIZE signal
parameter logic [2:0] SCR1_HSIZE_8B    = 3'b000;
parameter logic [2:0] SCR1_HSIZE_16B   = 3'b001;
parameter logic [2:0] SCR1_HSIZE_32B   = 3'b010;
parameter logic [2:0] SCR1_HSIZE_ERR   = 'x;

// Encoding HPROT signal
// HPROT[0] : 0 - instr;      1 - data
// HPROT[1] : 0 - user;       1 - privilege
// HPROT[2] : 0 - not buffer; 1 - buffer
// HPROT[3] : 0 - cacheable;  1 - cacheable
parameter SCR1_HPROT_DATA  = 0;
parameter SCR1_HPROT_PRV   = 1;
parameter SCR1_HPROT_BUF   = 2;
parameter SCR1_HPROT_CACHE = 3;

// Encoding HRESP signal
parameter logic SCR1_HRESP_OKAY  = 1'b0;
parameter logic SCR1_HRESP_ERROR = 1'b1;
parameter logic SCR1_HRESP_ERR   = 1'bx;

`endif // SCR1_AHB_SVH
