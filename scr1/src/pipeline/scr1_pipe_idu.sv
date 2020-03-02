/// Copyright by Syntacore LLC © 2016-2018. See LICENSE for details
/// @file       <scr1_pipe_idu.sv>
/// @brief      Instruction Decoder Unit (IDU)
///

`include "scr1_memif.svh"
`include "scr1_arch_types.svh"
`include "scr1_riscv_isa_decoding.svh"
`include "scr1_arch_description.svh"

module scr1_pipe_idu
(
`ifdef SCR1_SIM_ENV
    input   logic                           rst_n,
    input   logic                           clk,
`endif // SCR1_SIM_ENV

    // IFU <-> IDU interface
    output  logic                           idu2ifu_rdy,            // IDU ready for new data
    input   logic [`SCR1_IMEM_DWIDTH-1:0]   ifu2idu_instr,          // IFU instruction
    input   logic                           ifu2idu_imem_err,       // Instruction access fault exception
    input   logic                           ifu2idu_err_rvi_hi,     // 1 - imem fault when trying to fetch second half of an unaligned RVI instruction
    input   logic                           ifu2idu_vd,             // IFU request

    // IDU <-> EXU interface
    output  logic                           idu2exu_req,            // IDU request
    output  type_scr1_exu_cmd_s             idu2exu_cmd,            // IDU command
    output  logic                           idu2exu_use_rs1,        // Instruction uses rs1
    output  logic                           idu2exu_use_rs2,        // Instruction uses rs2
    output  logic                           idu2exu_use_rd,         // Instruction uses rd
    output  logic                           idu2exu_use_imm,        // Instruction uses immediate
    input   logic                           exu2idu_rdy,            // EXU ready for new data

    // chenrui, 20200224
    output  logic                           idu2exu_is_sm4_enc,
    output  logic                           idu2exu_is_sm4_key
);

//-------------------------------------------------------------------------------
// Local parameters declaration
//-------------------------------------------------------------------------------
localparam [SCR1_GPR_FIELD_WIDTH-1:0] SCR1_MPRF_ZERO_ADDR   = 5'd0;
localparam [SCR1_GPR_FIELD_WIDTH-1:0] SCR1_MPRF_RA_ADDR     = 5'd1;
localparam [SCR1_GPR_FIELD_WIDTH-1:0] SCR1_MPRF_SP_ADDR     = 5'd2;

//-------------------------------------------------------------------------------
// Local signals declaration
//-------------------------------------------------------------------------------

logic [`SCR1_IMEM_DWIDTH-1:0]       instr;
type_scr1_instr_type_e              instr_type;
type_scr1_rvi_opcode_e              rvi_opcode;
logic                               rvi_illegal;
logic [2:0]                         funct3;
logic [6:0]                         funct7;
logic [11:0]                        funct12;
logic [4:0]                         shamt;
`ifdef SCR1_RVC_EXT
logic                               rvc_illegal;
`endif  // SCR1_RVC_EXT
`ifdef SCR1_RVE_EXT
logic                               rve_illegal;
`endif  // SCR1_RVE_EXT

//-------------------------------------------------------------------------------
// Decode
//-------------------------------------------------------------------------------

assign idu2ifu_rdy  = exu2idu_rdy;
assign idu2exu_req  = ifu2idu_vd;
assign instr        = ifu2idu_instr;

// RVI / RVC
assign instr_type   = type_scr1_instr_type_e'(instr[1:0]);

// RVI / RVC fields
assign rvi_opcode   = type_scr1_rvi_opcode_e'(instr[6:2]);                          // RVI
assign funct3       = (instr_type == SCR1_INSTR_RVI) ? instr[14:12] : instr[15:13]; // RVI / RVC
assign funct7       = instr[31:25];                                                 // RVI
assign funct12      = instr[31:20];                                                 // RVI (SYSTEM)
assign shamt        = instr[24:20];                                                 // RVI

// RV32I(MC) decode
always_comb begin
    // Defaults
    idu2exu_cmd.instr_rvc   = 1'b0;
    idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_REG;
    idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_NONE;
    idu2exu_cmd.sum2_op     = SCR1_SUM2_OP_PC_IMM;
    idu2exu_cmd.lsu_cmd     = SCR1_LSU_CMD_NONE;
    idu2exu_cmd.csr_op      = SCR1_CSR_OP_REG;
    idu2exu_cmd.csr_cmd     = SCR1_CSR_CMD_NONE;
    idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_NONE;
    idu2exu_cmd.jump_req    = 1'b0;
    idu2exu_cmd.branch_req  = 1'b0;
    idu2exu_cmd.mret_req    = 1'b0;
    idu2exu_cmd.fencei_req  = 1'b0;
    idu2exu_cmd.wfi_req     = 1'b0;
    idu2exu_cmd.rs1_addr    = '0;
    idu2exu_cmd.rs2_addr    = '0;
    idu2exu_cmd.rd_addr     = '0;
    idu2exu_cmd.imm         = '0;
    idu2exu_cmd.exc_req     = 1'b0;
    idu2exu_cmd.exc_code    = SCR1_EXC_CODE_INSTR_MISALIGN;
    // Clock gating
    idu2exu_use_rs1         = 1'b0;
    idu2exu_use_rs2         = 1'b0;
    idu2exu_use_rd          = 1'b0;
    idu2exu_use_imm         = 1'b0;

    // chenrui, 20200224
    idu2exu_is_sm4_key      = 1'b0;
    idu2exu_is_sm4_enc      = 1'b0;

    rvi_illegal             = 1'b0;
`ifdef SCR1_RVE_EXT
    rve_illegal             = 1'b0;
`endif  // SCR1_RVE_EXT
`ifdef SCR1_RVC_EXT
    rvc_illegal             = 1'b0;
`endif  // SCR1_RVC_EXT

    // Check for IMEM access fault
    if (ifu2idu_imem_err) begin
        idu2exu_cmd.exc_req     = 1'b1;
        idu2exu_cmd.exc_code    = SCR1_EXC_CODE_INSTR_ACCESS_FAULT;
        idu2exu_cmd.instr_rvc   = ifu2idu_err_rvi_hi;
    end else begin  // no imem fault
        case (instr_type)
            SCR1_INSTR_RVI  : begin
                idu2exu_cmd.rs1_addr    = instr[19:15];
                idu2exu_cmd.rs2_addr    = instr[24:20];
                idu2exu_cmd.rd_addr     = instr[11:7];
                case (rvi_opcode)
                    SCR1_OPCODE_AUIPC           : begin
                        idu2exu_use_rd          = 1'b1;
                        idu2exu_use_imm         = 1'b1;
                        idu2exu_cmd.sum2_op     = SCR1_SUM2_OP_PC_IMM;
                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_SUM2;
                        idu2exu_cmd.imm         = {instr[31:12], 12'b0};
`ifdef SCR1_RVE_EXT
                        if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_AUIPC

                    SCR1_OPCODE_LUI             : begin
                        idu2exu_use_rd          = 1'b1;
                        idu2exu_use_imm         = 1'b1;
                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IMM;
                        idu2exu_cmd.imm         = {instr[31:12], 12'b0};
`ifdef SCR1_RVE_EXT
                        if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_LUI

                    SCR1_OPCODE_JAL             : begin
                        idu2exu_use_rd          = 1'b1;
                        idu2exu_use_imm         = 1'b1;
                        idu2exu_cmd.sum2_op     = SCR1_SUM2_OP_PC_IMM;
                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_INC_PC;
                        idu2exu_cmd.jump_req    = 1'b1;
                        idu2exu_cmd.imm         = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
`ifdef SCR1_RVE_EXT
                        if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_JAL

                    SCR1_OPCODE_LOAD            : begin
                        idu2exu_use_rs1         = 1'b1;
                        idu2exu_use_rd          = 1'b1;
                        idu2exu_use_imm         = 1'b1;
                        idu2exu_cmd.sum2_op     = SCR1_SUM2_OP_REG_IMM;
                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_LSU;
                        idu2exu_cmd.imm         = {{21{instr[31]}}, instr[30:20]};
                        case (funct3)
                            3'b000  : idu2exu_cmd.lsu_cmd = SCR1_LSU_CMD_LB;
                            3'b001  : idu2exu_cmd.lsu_cmd = SCR1_LSU_CMD_LH;
                            3'b010  : idu2exu_cmd.lsu_cmd = SCR1_LSU_CMD_LW;
                            3'b100  : idu2exu_cmd.lsu_cmd = SCR1_LSU_CMD_LBU;
                            3'b101  : idu2exu_cmd.lsu_cmd = SCR1_LSU_CMD_LHU;
                            default : rvi_illegal = 1'b1;
                        endcase // funct3
`ifdef SCR1_RVE_EXT
                        if (instr[11] | instr[19])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_LOAD

                    SCR1_OPCODE_STORE           : begin
                        idu2exu_use_rs1         = 1'b1;
                        idu2exu_use_rs2         = 1'b1;
                        idu2exu_use_imm         = 1'b1;
                        idu2exu_cmd.sum2_op     = SCR1_SUM2_OP_REG_IMM;
                        idu2exu_cmd.imm         = {{21{instr[31]}}, instr[30:25], instr[11:7]};
                        case (funct3)
                            3'b000  : idu2exu_cmd.lsu_cmd = SCR1_LSU_CMD_SB;
                            3'b001  : idu2exu_cmd.lsu_cmd = SCR1_LSU_CMD_SH;
                            3'b010  : idu2exu_cmd.lsu_cmd = SCR1_LSU_CMD_SW;
                            default : rvi_illegal = 1'b1;
                        endcase // funct3
`ifdef SCR1_RVE_EXT
                        if (instr[19] | instr[24])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_STORE


                    // CHENRUI, 20200217
                    SCR1_OPCODE_CUSTOM0: begin
                        idu2exu_use_rs1         = 1'b1; 
                        idu2exu_use_rd          = 1'b1;
                        idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_IMM;
                        idu2exu_use_imm         = 1'b1;
                        idu2exu_cmd.imm         = '0;
                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IALU;
                        case(funct3)
                            3'b001: begin
                                idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_SM4KEY; 
                                idu2exu_is_sm4_key      = 1'b1;
                            end

                            3'b010: begin
                                if(instr[11:7] == 5'd28 ) begin
                                    idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_SM4ENC; 
                                    idu2exu_is_sm4_enc      = 1'b1;
                                end else begin
                                    rvi_illegal = 1'b1;
                                end
                            end
                            
                            default:rvi_illegal = 1'b1;
                        endcase
                    end

                    SCR1_OPCODE_OP              : begin
                        idu2exu_use_rs1         = 1'b1;
                        idu2exu_use_rs2         = 1'b1;
                        idu2exu_use_rd          = 1'b1;
                        idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_REG;
                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IALU;
                        case (funct7)
                            7'b0000000 : begin
                                case (funct3)
                                    3'b000  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_ADD;
                                    3'b001  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_SLL;
                                    3'b010  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_SUB_LT;
                                    3'b011  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_SUB_LTU;
                                    3'b100  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_XOR;
                                    3'b101  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_SRL;
                                    3'b110  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_OR;
                                    3'b111  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_AND;
                                endcase // funct3
                            end // 7'b0000000

                            7'b0100000 : begin
                                case (funct3)
                                    3'b000  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_SUB;
                                    3'b101  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_SRA;
                                    default : rvi_illegal = 1'b1;
                                endcase // funct3
                            end // 7'b0100000
`ifdef SCR1_RVM_EXT
                            7'b0000001 : begin
                                case (funct3)
                                    3'b000  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_MUL;
                                    3'b001  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_MULH;
                                    3'b010  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_MULHSU;
                                    3'b011  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_MULHU;
                                    3'b100  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_DIV;
                                    3'b101  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_DIVU;
                                    3'b110  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_REM;
                                    3'b111  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_REMU;
                                endcase // funct3
                            end // 7'b0000001
`endif  // SCR1_RVM_EXT
                            default : rvi_illegal = 1'b1;
                        endcase // funct7
`ifdef SCR1_RVE_EXT
                        if (instr[11] | instr[19] | instr[24])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_OP

                    SCR1_OPCODE_OP_IMM          : begin
                        idu2exu_use_rs1         = 1'b1;
                        idu2exu_use_rd          = 1'b1;
                        idu2exu_use_imm         = 1'b1;
                        idu2exu_cmd.imm         = {{21{instr[31]}}, instr[30:20]};
                        idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_IMM;
                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IALU;
                        case (funct3)
                            3'b000  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_ADD;        // ADDI
                            3'b010  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_SUB_LT;     // SLTI
                            3'b011  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_SUB_LTU;    // SLTIU
                            3'b100  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_XOR;        // XORI
                            3'b110  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_OR;         // ORI
                            3'b111  : idu2exu_cmd.ialu_cmd  = SCR1_IALU_CMD_AND;        // ANDI
                            3'b001  : begin
                                case (funct7)
                                    7'b0000000  : begin
                                        // SLLI
                                        idu2exu_cmd.imm         = `SCR1_XLEN'(shamt);   // zero-extend
                                        idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_SLL;
                                    end
                                    default     : rvi_illegal   = 1'b1;
                                endcase // funct7
                            end
                            3'b101  : begin
                                case (funct7)
                                    7'b0000000  : begin
                                        // SRLI
                                        idu2exu_cmd.imm         = `SCR1_XLEN'(shamt);   // zero-extend
                                        idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_SRL;
                                    end
                                    7'b0100000  : begin
                                        // SRAI
                                        idu2exu_cmd.imm         = `SCR1_XLEN'(shamt);   // zero-extend
                                        idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_SRA;
                                    end
                                    default     : rvi_illegal   = 1'b1;
                                endcase // funct7
                            end
                        endcase // funct3
`ifdef SCR1_RVE_EXT
                        if (instr[11] | instr[19])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_OP_IMM

                    SCR1_OPCODE_MISC_MEM    : begin
                        case (funct3)
                            3'b000  : begin
                                if (~|{instr[31:28], instr[19:15], instr[11:7]}) begin
                                    // FENCE = NOP
                                end
                                else rvi_illegal = 1'b1;
                            end
                            3'b001  : begin
                                if (~|{instr[31:15], instr[11:7]}) begin
                                    // FENCE.I
                                    idu2exu_cmd.fencei_req    = 1'b1;
                                end
                                else rvi_illegal = 1'b1;
                            end
                            default : rvi_illegal = 1'b1;
                        endcase // funct3
                    end // SCR1_OPCODE_MISC_MEM

                    SCR1_OPCODE_BRANCH          : begin
                        idu2exu_use_rs1         = 1'b1;
                        idu2exu_use_rs2         = 1'b1;
                        idu2exu_use_imm         = 1'b1;
                        idu2exu_cmd.imm         = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
                        idu2exu_cmd.branch_req  = 1'b1;
                        idu2exu_cmd.sum2_op     = SCR1_SUM2_OP_PC_IMM;
                        idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_REG;
                        case (funct3)
                            3'b000  : idu2exu_cmd.ialu_cmd = SCR1_IALU_CMD_SUB_EQ;
                            3'b001  : idu2exu_cmd.ialu_cmd = SCR1_IALU_CMD_SUB_NE;
                            3'b100  : idu2exu_cmd.ialu_cmd = SCR1_IALU_CMD_SUB_LT;
                            3'b101  : idu2exu_cmd.ialu_cmd = SCR1_IALU_CMD_SUB_GE;
                            3'b110  : idu2exu_cmd.ialu_cmd = SCR1_IALU_CMD_SUB_LTU;
                            3'b111  : idu2exu_cmd.ialu_cmd = SCR1_IALU_CMD_SUB_GEU;
                            default : rvi_illegal = 1'b1;
                        endcase // funct3
`ifdef SCR1_RVE_EXT
                        if (instr[19] | instr[24])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_BRANCH

                    SCR1_OPCODE_JALR        : begin
                        idu2exu_use_rs1     = 1'b1;
                        idu2exu_use_rd      = 1'b1;
                        idu2exu_use_imm     = 1'b1;
                        case (funct3)
                            3'b000  : begin
                                // JALR
                                idu2exu_cmd.sum2_op   = SCR1_SUM2_OP_REG_IMM;
                                idu2exu_cmd.rd_wb_sel = SCR1_RD_WB_INC_PC;
                                idu2exu_cmd.jump_req  = 1'b1;
                                idu2exu_cmd.imm       = {{21{instr[31]}}, instr[30:20]};
                            end
                            default : rvi_illegal = 1'b1;
                        endcase
`ifdef SCR1_RVE_EXT
                        if (instr[11] | instr[19])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_JALR

                    SCR1_OPCODE_SYSTEM      : begin
                        idu2exu_use_rd      = 1'b1;
                        idu2exu_use_imm     = 1'b1;
                        idu2exu_cmd.imm     = `SCR1_XLEN'({funct3, instr[31:20]});      // {funct3, CSR address}
                        case (funct3)
                            3'b000  : begin
                                idu2exu_use_rd    = 1'b0;
                                idu2exu_use_imm   = 1'b0;
                                case ({instr[19:15], instr[11:7]})
                                    10'd0 : begin
                                        case (funct12)
                                            12'h000 : begin
                                                // ECALL
                                                idu2exu_cmd.exc_req     = 1'b1;
                                                idu2exu_cmd.exc_code    = SCR1_EXC_CODE_ECALL_M;
                                            end
                                            12'h001 : begin
                                                // EBREAK
                                                idu2exu_cmd.exc_req     = 1'b1;
                                                idu2exu_cmd.exc_code    = SCR1_EXC_CODE_BREAKPOINT;
                                            end
                                            12'h302 : begin
                                                // MRET
                                                idu2exu_cmd.mret_req    = 1'b1;
                                            end
                                            12'h105 : begin
                                                // WFI
                                                idu2exu_cmd.wfi_req     = 1'b1;
                                            end
                                            default : rvi_illegal = 1'b1;
                                        endcase // funct12
                                    end
                                    default : rvi_illegal = 1'b1;
                                endcase // {instr[19:15], instr[11:7]}
                            end
                            3'b001  : begin
                                // CSRRW
                                idu2exu_use_rs1             = 1'b1;
                                idu2exu_cmd.rd_wb_sel       = SCR1_RD_WB_CSR;
                                idu2exu_cmd.csr_cmd         = SCR1_CSR_CMD_WRITE;
                                idu2exu_cmd.csr_op          = SCR1_CSR_OP_REG;
`ifdef SCR1_RVE_EXT
                                if (instr[11] | instr[19])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end
                            3'b010  : begin
                                // CSRRS
                                idu2exu_use_rs1             = 1'b1;
                                idu2exu_cmd.rd_wb_sel       = SCR1_RD_WB_CSR;
                                idu2exu_cmd.csr_cmd         = SCR1_CSR_CMD_SET;
                                idu2exu_cmd.csr_op          = SCR1_CSR_OP_REG;
`ifdef SCR1_RVE_EXT
                                if (instr[11] | instr[19])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end
                            3'b011  : begin
                                // CSRRC
                                idu2exu_use_rs1             = 1'b1;
                                idu2exu_cmd.rd_wb_sel       = SCR1_RD_WB_CSR;
                                idu2exu_cmd.csr_cmd         = SCR1_CSR_CMD_CLEAR;
                                idu2exu_cmd.csr_op          = SCR1_CSR_OP_REG;
`ifdef SCR1_RVE_EXT
                                if (instr[11] | instr[19])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end
                            3'b101  : begin
                                // CSRRWI
                                idu2exu_use_rs1             = 1'b1;             // zimm
                                idu2exu_cmd.rd_wb_sel       = SCR1_RD_WB_CSR;
                                idu2exu_cmd.csr_cmd         = SCR1_CSR_CMD_WRITE;
                                idu2exu_cmd.csr_op          = SCR1_CSR_OP_IMM;
`ifdef SCR1_RVE_EXT
                                if (instr[11])              rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end
                            3'b110  : begin
                                // CSRRSI
                                idu2exu_use_rs1             = 1'b1;             // zimm
                                idu2exu_cmd.rd_wb_sel       = SCR1_RD_WB_CSR;
                                idu2exu_cmd.csr_cmd         = SCR1_CSR_CMD_SET;
                                idu2exu_cmd.csr_op          = SCR1_CSR_OP_IMM;
`ifdef SCR1_RVE_EXT
                                if (instr[11])              rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end
                            3'b111  : begin
                                // CSRRCI
                                idu2exu_use_rs1             = 1'b1;             // zimm
                                idu2exu_cmd.rd_wb_sel       = SCR1_RD_WB_CSR;
                                idu2exu_cmd.csr_cmd         = SCR1_CSR_CMD_CLEAR;
                                idu2exu_cmd.csr_op          = SCR1_CSR_OP_IMM;
`ifdef SCR1_RVE_EXT
                                if (instr[11])              rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end
                            default : rvi_illegal = 1'b1;
                        endcase // funct3
                    end // SCR1_OPCODE_SYSTEM

                    default : begin
                        rvi_illegal = 1'b1;
                    end
                endcase // rvi_opcode
            end // SCR1_INSTR_RVI

`ifdef SCR1_RVC_EXT

            // Quadrant 0
            SCR1_INSTR_RVC0 : begin
                idu2exu_cmd.instr_rvc   = 1'b1;
                idu2exu_use_rs1         = 1'b1;
                idu2exu_use_imm         = 1'b1;
                case (funct3)
                    3'b000  : begin
                        if (~|instr[12:5])      rvc_illegal = 1'b1;
                        // C.ADDI4SPN
                        idu2exu_use_rd          = 1'b1;
                        idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_ADD;
                        idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_IMM;
                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IALU;
                        idu2exu_cmd.rs1_addr    = SCR1_MPRF_SP_ADDR;
                        idu2exu_cmd.rd_addr     = {2'b01, instr[4:2]};
                        idu2exu_cmd.imm         = {22'd0, instr[10:7], instr[12:11], instr[5], instr[6], 2'b00};
                    end
                    3'b010  : begin
                        // C.LW
                        idu2exu_use_rd          = 1'b1;
                        idu2exu_cmd.sum2_op     = SCR1_SUM2_OP_REG_IMM;
                        idu2exu_cmd.lsu_cmd     = SCR1_LSU_CMD_LW;
                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_LSU;
                        idu2exu_cmd.rs1_addr    = {2'b01, instr[9:7]};
                        idu2exu_cmd.rd_addr     = {2'b01, instr[4:2]};
                        idu2exu_cmd.imm         = {25'd0, instr[5], instr[12:10], instr[6], 2'b00};
                    end
                    3'b110  : begin
                        // C.SW
                        idu2exu_use_rs2         = 1'b1;
                        idu2exu_cmd.sum2_op     = SCR1_SUM2_OP_REG_IMM;
                        idu2exu_cmd.lsu_cmd     = SCR1_LSU_CMD_SW;
                        idu2exu_cmd.rs1_addr    = {2'b01, instr[9:7]};
                        idu2exu_cmd.rs2_addr    = {2'b01, instr[4:2]};
                        idu2exu_cmd.imm         = {25'd0, instr[5], instr[12:10], instr[6], 2'b00};
                    end
                    default : begin
                        rvc_illegal = 1'b1;
                    end
                endcase // funct3
            end // Quadrant 0

            // Quadrant 1
            SCR1_INSTR_RVC1 : begin
                idu2exu_cmd.instr_rvc   = 1'b1;
                idu2exu_use_rd          = 1'b1;
                idu2exu_use_imm         = 1'b1;
                case (funct3)
                    3'b000  : begin
                        // C.ADDI / C.NOP
                        idu2exu_use_rs1         = 1'b1;
                        idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_ADD;
                        idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_IMM;
                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IALU;
                        idu2exu_cmd.rs1_addr    = instr[11:7];
                        idu2exu_cmd.rd_addr     = instr[11:7];
                        idu2exu_cmd.imm         = {{27{instr[12]}}, instr[6:2]};
`ifdef SCR1_RVE_EXT
                        if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end
                    3'b001  : begin
                        // C.JAL
                        idu2exu_cmd.sum2_op     = SCR1_SUM2_OP_PC_IMM;
                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_INC_PC;
                        idu2exu_cmd.jump_req    = 1'b1;
                        idu2exu_cmd.rd_addr     = SCR1_MPRF_RA_ADDR;
                        idu2exu_cmd.imm         = {{21{instr[12]}}, instr[8], instr[10:9], instr[6], instr[7], instr[2], instr[11], instr[5:3], 1'b0};
                    end
                    3'b010  : begin
                        // C.LI
                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IMM;
                        idu2exu_cmd.rd_addr     = instr[11:7];
                        idu2exu_cmd.imm         = {{27{instr[12]}}, instr[6:2]};
`ifdef SCR1_RVE_EXT
                        if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end
                    3'b011  : begin
                        if (~|{instr[12], instr[6:2]}) rvc_illegal = 1'b1;
                        if (instr[11:7] == SCR1_MPRF_SP_ADDR) begin
                            // C.ADDI16SP
                            idu2exu_use_rs1         = 1'b1;
                            idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_ADD;
                            idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_IMM;
                            idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IALU;
                            idu2exu_cmd.rs1_addr    = SCR1_MPRF_SP_ADDR;
                            idu2exu_cmd.rd_addr     = SCR1_MPRF_SP_ADDR;
                            idu2exu_cmd.imm         = {{23{instr[12]}}, instr[4:3], instr[5], instr[2], instr[6], 4'd0};
                        end else begin
                            // C.LUI
                            idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IMM;
                            idu2exu_cmd.rd_addr     = instr[11:7];
                            idu2exu_cmd.imm         = {{15{instr[12]}}, instr[6:2], 12'd0};
`ifdef SCR1_RVE_EXT
                            if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                        end
                    end
                    3'b100  : begin
                        idu2exu_cmd.rs1_addr    = {2'b01, instr[9:7]};
                        idu2exu_cmd.rd_addr     = {2'b01, instr[9:7]};
                        idu2exu_cmd.rs2_addr    = {2'b01, instr[4:2]};
                        idu2exu_use_rs1         = 1'b1;
                        idu2exu_use_rd          = 1'b1;
                        case (instr[11:10])
                            2'b00   : begin
                                if (instr[12])          rvc_illegal = 1'b1;
                                // C.SRLI
                                idu2exu_use_imm         = 1'b1;
                                idu2exu_cmd.imm         = {27'd0, instr[6:2]};
                                idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_SRL;
                                idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_IMM;
                                idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IALU;
                            end
                            2'b01   : begin
                                if (instr[12])          rvc_illegal = 1'b1;
                                // C.SRAI
                                idu2exu_use_imm         = 1'b1;
                                idu2exu_cmd.imm         = {27'd0, instr[6:2]};
                                idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_SRA;
                                idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_IMM;
                                idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IALU;
                            end
                            2'b10   : begin
                                // C.ANDI
                                idu2exu_use_imm         = 1'b1;
                                idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_AND;
                                idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_IMM;
                                idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IALU;
                                idu2exu_cmd.imm         = {{27{instr[12]}}, instr[6:2]};
                            end
                            2'b11   : begin
                                idu2exu_use_rs2         = 1'b1;
                                case ({instr[12], instr[6:5]})
                                    3'b000  : begin
                                        // C.SUB
                                        idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_SUB;
                                        idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_REG;
                                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IALU;
                                    end
                                    3'b001  : begin
                                        // C.XOR
                                        idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_XOR;
                                        idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_REG;
                                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IALU;
                                    end
                                    3'b010  : begin
                                        // C.OR
                                        idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_OR;
                                        idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_REG;
                                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IALU;
                                    end
                                    3'b011  : begin
                                        // C.AND
                                        idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_AND;
                                        idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_REG;
                                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IALU;
                                    end
                                    default : begin
                                        rvc_illegal = 1'b1;
                                    end
                                endcase // {instr[12], instr[6:5]}
                            end
                        endcase // instr[11:10]
                    end // funct3 == 3'b100
                    3'b101  : begin
                        // C.J
                        idu2exu_use_imm         = 1'b1;
                        idu2exu_cmd.sum2_op     = SCR1_SUM2_OP_PC_IMM;
                        idu2exu_cmd.jump_req    = 1'b1;
                        idu2exu_cmd.imm         = {{21{instr[12]}}, instr[8], instr[10:9], instr[6], instr[7], instr[2], instr[11], instr[5:3], 1'b0};
                    end
                    3'b110  : begin
                        // C.BEQZ
                        idu2exu_use_rs1         = 1'b1;
                        idu2exu_use_rs2         = 1'b1;
                        idu2exu_use_imm         = 1'b1;
                        idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_SUB_EQ;
                        idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_REG;
                        idu2exu_cmd.sum2_op     = SCR1_SUM2_OP_PC_IMM;
                        idu2exu_cmd.branch_req  = 1'b1;
                        idu2exu_cmd.rs1_addr    = {2'b01, instr[9:7]};
                        idu2exu_cmd.rs2_addr    = SCR1_MPRF_ZERO_ADDR;
                        idu2exu_cmd.imm         = {{24{instr[12]}}, instr[6:5], instr[2], instr[11:10], instr[4:3], 1'b0};
                    end
                    3'b111  : begin
                        // C.BNEZ
                        idu2exu_use_rs1         = 1'b1;
                        idu2exu_use_rs2         = 1'b1;
                        idu2exu_use_imm         = 1'b1;
                        idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_SUB_NE;
                        idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_REG;
                        idu2exu_cmd.sum2_op     = SCR1_SUM2_OP_PC_IMM;
                        idu2exu_cmd.branch_req  = 1'b1;
                        idu2exu_cmd.rs1_addr    = {2'b01, instr[9:7]};
                        idu2exu_cmd.rs2_addr    = SCR1_MPRF_ZERO_ADDR;
                        idu2exu_cmd.imm         = {{24{instr[12]}}, instr[6:5], instr[2], instr[11:10], instr[4:3], 1'b0};
                    end
                endcase // funct3
            end // Quadrant 1

            // Quadrant 2
            SCR1_INSTR_RVC2 : begin
                idu2exu_cmd.instr_rvc   = 1'b1;
                idu2exu_use_rs1         = 1'b1;
                case (funct3)
                    3'b000  : begin
                        if (instr[12])          rvc_illegal = 1'b1;
                        // C.SLLI
                        idu2exu_use_rd          = 1'b1;
                        idu2exu_use_imm         = 1'b1;
                        idu2exu_cmd.rs1_addr    = instr[11:7];
                        idu2exu_cmd.rd_addr     = instr[11:7];
                        idu2exu_cmd.imm         = {27'd0, instr[6:2]};
                        idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_SLL;
                        idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_IMM;
                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IALU;
`ifdef SCR1_RVE_EXT
                        if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end
                    3'b010  : begin
                        if (~|instr[11:7])      rvc_illegal = 1'b1;
                        // C.LWSP
                        idu2exu_use_rd          = 1'b1;
                        idu2exu_use_imm         = 1'b1;
                        idu2exu_cmd.sum2_op     = SCR1_SUM2_OP_REG_IMM;
                        idu2exu_cmd.lsu_cmd     = SCR1_LSU_CMD_LW;
                        idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_LSU;
                        idu2exu_cmd.rs1_addr    = SCR1_MPRF_SP_ADDR;
                        idu2exu_cmd.rd_addr     = instr[11:7];
                        idu2exu_cmd.imm         = {24'd0, instr[3:2], instr[12], instr[6:4], 2'b00};
`ifdef SCR1_RVE_EXT
                        if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end
                    3'b100  : begin
                        if (~instr[12]) begin
                            if (|instr[6:2]) begin
                                // C.MV
                                idu2exu_use_rs2         = 1'b1;
                                idu2exu_use_rd          = 1'b1;
                                idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_ADD;
                                idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_REG;
                                idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IALU;
                                idu2exu_cmd.rs1_addr    = SCR1_MPRF_ZERO_ADDR;
                                idu2exu_cmd.rs2_addr    = instr[6:2];
                                idu2exu_cmd.rd_addr     = instr[11:7];
`ifdef SCR1_RVE_EXT
                                if (instr[11]|instr[6]) rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end else begin
                                if (~|instr[11:7])      rvc_illegal = 1'b1;
                                // C.JR
                                idu2exu_use_imm         = 1'b1;
                                idu2exu_cmd.sum2_op     = SCR1_SUM2_OP_REG_IMM;
                                idu2exu_cmd.jump_req    = 1'b1;
                                idu2exu_cmd.rs1_addr    = instr[11:7];
                                idu2exu_cmd.imm         = 0;
`ifdef SCR1_RVE_EXT
                                if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end
                        end else begin  // instr[12] == 1
                            if (~|instr[11:2]) begin
                                // C.EBREAK
                                idu2exu_cmd.exc_req     = 1'b1;
                                idu2exu_cmd.exc_code    = SCR1_EXC_CODE_BREAKPOINT;
                            end else if (~|instr[6:2]) begin
                                // C.JALR
                                idu2exu_use_rs1         = 1'b1;
                                idu2exu_use_rd          = 1'b1;
                                idu2exu_use_imm         = 1'b1;
                                idu2exu_cmd.sum2_op     = SCR1_SUM2_OP_REG_IMM;
                                idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_INC_PC;
                                idu2exu_cmd.jump_req    = 1'b1;
                                idu2exu_cmd.rs1_addr    = instr[11:7];
                                idu2exu_cmd.rd_addr     = SCR1_MPRF_RA_ADDR;
                                idu2exu_cmd.imm         = 0;
`ifdef SCR1_RVE_EXT
                                if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end else begin
                                // C.ADD
                                idu2exu_use_rs1         = 1'b1;
                                idu2exu_use_rs2         = 1'b1;
                                idu2exu_use_rd          = 1'b1;
                                idu2exu_cmd.ialu_cmd    = SCR1_IALU_CMD_ADD;
                                idu2exu_cmd.ialu_op     = SCR1_IALU_OP_REG_REG;
                                idu2exu_cmd.rd_wb_sel   = SCR1_RD_WB_IALU;
                                idu2exu_cmd.rs1_addr    = instr[11:7];
                                idu2exu_cmd.rs2_addr    = instr[6:2];
                                idu2exu_cmd.rd_addr     = instr[11:7];
`ifdef SCR1_RVE_EXT
                                if (instr[11]|instr[6]) rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end
                        end // instr[12] == 1
                    end
                    3'b110  : begin
                        // C.SWSP
                        idu2exu_use_rs1         = 1'b1;
                        idu2exu_use_rs2         = 1'b1;
                        idu2exu_use_imm         = 1'b1;
                        idu2exu_cmd.sum2_op     = SCR1_SUM2_OP_REG_IMM;
                        idu2exu_cmd.lsu_cmd     = SCR1_LSU_CMD_SW;
                        idu2exu_cmd.rs1_addr    = SCR1_MPRF_SP_ADDR;
                        idu2exu_cmd.rs2_addr    = instr[6:2];
                        idu2exu_cmd.imm         = {24'd0, instr[8:7], instr[12:9], 2'b00};
`ifdef SCR1_RVE_EXT
                        if (instr[6])           rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end
                    default : begin
                        rvc_illegal = 1'b1;
                    end
                endcase // funct3
            end // Quadrant 2

            default         : begin
            end
`else   // SCR1_RVC_EXT
            default         : begin
                idu2exu_cmd.instr_rvc   = 1'b1;
                rvi_illegal             = 1'b1;
            end
`endif  // SCR1_RVC_EXT
        endcase // instr_type
    end // no imem fault

    // At this point the instruction is fully decoded
    // given that no imem fault has happened

    // Check illegal instruction
    if (
    rvi_illegal
`ifdef SCR1_RVC_EXT
    | rvc_illegal
`endif
`ifdef SCR1_RVE_EXT
    | rve_illegal
`endif
    ) begin
        idu2exu_cmd.ialu_cmd        = SCR1_IALU_CMD_NONE;
        idu2exu_cmd.lsu_cmd         = SCR1_LSU_CMD_NONE;
        idu2exu_cmd.csr_cmd         = SCR1_CSR_CMD_NONE;
        idu2exu_cmd.rd_wb_sel       = SCR1_RD_WB_NONE;
        idu2exu_cmd.jump_req        = 1'b0;
        idu2exu_cmd.branch_req      = 1'b0;
        idu2exu_cmd.mret_req        = 1'b0;
        idu2exu_cmd.fencei_req      = 1'b0;
        idu2exu_cmd.wfi_req         = 1'b0;

        idu2exu_use_rs1             = 1'b0;
        idu2exu_use_rs2             = 1'b0;
        idu2exu_use_rd              = 1'b0;

`ifndef SCR1_MTVAL_ILLEGAL_INSTR_EN
        idu2exu_use_imm             = 1'b0;
`else // SCR1_MTVAL_ILLEGAL_INSTR_EN
        idu2exu_use_imm             = 1'b1;
        idu2exu_cmd.imm             = instr;
`endif // SCR1_MTVAL_ILLEGAL_INSTR_EN

        idu2exu_cmd.exc_req         = 1'b1;
        idu2exu_cmd.exc_code        = SCR1_EXC_CODE_ILLEGAL_INSTR;
    end

end // RV32I(MC) decode

`ifdef SCR1_SIM_ENV
`ifndef VERILATOR
//-------------------------------------------------------------------------------
// Assertion
//-------------------------------------------------------------------------------

// X checks

SCR1_SVA_IDU_XCHECK : assert property (
    @(negedge clk) disable iff (~rst_n)
    !$isunknown({ifu2idu_vd, exu2idu_rdy})
    ) else $error("IDU Error: unknown values");

SCR1_SVA_IDU_XCHECK2 : assert property (
    @(negedge clk) disable iff (~rst_n)
    ifu2idu_vd |-> !$isunknown({ifu2idu_imem_err, (ifu2idu_imem_err ? 0 : ifu2idu_instr)})
    ) else $error("IDU Error: unknown values");

// Behavior checks

SCR1_SVA_IDU_IALU_CMD_RANGE : assert property (
    @(negedge clk) disable iff (~rst_n)
    (ifu2idu_vd & ~ifu2idu_imem_err) |->
    ((idu2exu_cmd.ialu_cmd >= SCR1_IALU_CMD_NONE) &
    (idu2exu_cmd.ialu_cmd <=
`ifdef SCR1_RVM_EXT
                            SCR1_IALU_CMD_REMU
`else
                            SCR1_IALU_CMD_SRA
`endif // SCR1_RVM_EXT
        ))
    ) else $error("IDU Error: IALU_CMD out of range");

`endif // VERILATOR
`endif // SCR1_SIM_ENV

endmodule : scr1_pipe_idu
