// ================================================================================
// File          : sm4lt.sv
// File Created  : Sunday, 9th February 2020 10:21:25 am
// Author        : RUI CHEN (chenrui@niit.edu.cn)
// Copyright 2017 - 2020 Nanjing Institute of Industry Technology
// --------------------------------------------------------------------------------
// Description   : 
//               : 
//               : 
// --------------------------------------------------------------------------------
// Modified By   : RUI CHEN (chenrui@niit.edu.cn>)
// Last Modified : Monday, 17th February 2020 7:41:04 pm
// ================================================================================
module sm4lt(
    input  logic mode_i,
    input  logic [31:0] data_i  ,
    output logic [31:0] result_o
);

    logic [31:0] temp_d    ;
    logic [31:0] result_enc;
    logic [31:0] result_key;
    sbox u_b3(.din(data_i[4*8-1:3*8]), .dout(temp_d[4*8-1:3*8]));
    sbox u_b2(.din(data_i[3*8-1:2*8]), .dout(temp_d[3*8-1:2*8]));
    sbox u_b1(.din(data_i[2*8-1:1*8]), .dout(temp_d[2*8-1:1*8]));
    sbox u_b0(.din(data_i[1*8-1:0*8]), .dout(temp_d[1*8-1:0*8]));

    // assign result_enc = temp_d 
    //                 ^ {temp_d[29:0], temp_d[31:30]}
    //                 ^ {temp_d[21:0], temp_d[31:22]}
    //                 ^ {temp_d[13:0], temp_d[31:14]}
    //                 ^ {temp_d[7 :0], temp_d[31:8 ]};
    // assign result_key = temp_d 
    //                 ^ {temp_d[18:0], temp_d[31:19]}
    //                 ^ {temp_d[ 8:0], temp_d[31: 9]};
    // assign  result_o = (mode_i == 1'b1) ? result_enc : result_key;

    assign result_o = temp_d
                    ^ ((mode_i == 1'b1) ? {temp_d[29:0], temp_d[31:30]} : {temp_d[18:0], temp_d[31:19]})
                    ^ ((mode_i == 1'b1) ? {temp_d[21:0], temp_d[31:22]} : {temp_d[ 8:0], temp_d[31: 9]})
                    ^ ((mode_i == 1'b1) ? {temp_d[13:0], temp_d[31:14]} : 32'd0)
                    ^ ((mode_i == 1'b1) ? {temp_d[7 :0], temp_d[31:8 ]} : 32'd0);
endmodule