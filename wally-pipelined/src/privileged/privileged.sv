///////////////////////////////////////////
// privileged.sv
//
// Written: David_Harris@hmc.edu 5 January 2021
// Modified: 
//
// Purpose: Implements the CSRs, Exceptions, and Privileged operations
//          See RISC-V Privileged Mode Specification 20190608 
// 
// A component of the Wally configurable RISC-V project.
// 
// Copyright (C) 2021 Harvey Mudd College & Oklahoma State University
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, 
// modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software 
// is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES 
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS 
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT 
// OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
///////////////////////////////////////////

`include "wally-config.vh"

module privileged (
  input  logic             clk, reset,
  input  logic             FlushW,
  input  logic             CSRReadM, CSRWriteM,
  input  logic [`XLEN-1:0] SrcAM,
  input  logic [31:0]      InstrM,
  input  logic [`XLEN-1:0] PCM,
  output logic [`XLEN-1:0] CSRReadValW,
  output logic [`XLEN-1:0] PrivilegedNextPCM,
  output logic             RetM, TrapM,
  output logic             ITLBFlushF, DTLBFlushM,
  input  logic             InstrValidW, FloatRegWriteW, LoadStallD,
  input  logic 		   BPPredDirWrongM,
  input  logic 		   BTBPredPCWrongM,
  input  logic 		   RASPredPCWrongM,
  input  logic 		   BPPredClassNonCFIWrongM,
  input  logic [4:0]       InstrClassM,
  input  logic             PrivilegedM,
  input  logic             ITLBInstrPageFaultF, DTLBLoadPageFaultM, DTLBStorePageFaultM,
  input  logic             WalkerInstrPageFaultF, WalkerLoadPageFaultM, WalkerStorePageFaultM,
  input  logic             InstrMisalignedFaultM, IllegalIEUInstrFaultD,
  input  logic             LoadMisalignedFaultM,
  input  logic             StoreMisalignedFaultM,
  input  logic             TimerIntM, ExtIntM, SwIntM,
  input  logic [`XLEN-1:0] InstrMisalignedAdrM, MemAdrM,
  input  logic [4:0]       SetFflagsM,
  output logic [1:0]       PrivilegeModeW,
  output logic [`XLEN-1:0] SATP_REGW,
  output logic             STATUS_MXR, STATUS_SUM,
  output logic [2:0]       FRM_REGW,
  input  logic             FlushD, FlushE, FlushM, StallD, StallW, StallE, StallM,

  // PMA checker signals
  input  logic [31:0]      HADDR,
  input  logic [2:0]       HSIZE, HBURST,
  input  logic             HWRITE,
  input  logic             AtomicAccessM, ExecuteAccessF, WriteAccessM, ReadAccessM,
  output logic             Cacheable, Idempotent, AtomicAllowed,
  output logic             SquashBusAccess,
  output logic [5:0]       HSELRegions
);

  logic [1:0] NextPrivilegeModeM;

  logic [`XLEN-1:0] CauseM, NextFaultMtvalM;
  logic [`XLEN-1:0] MEPC_REGW, SEPC_REGW, UEPC_REGW, UTVEC_REGW, STVEC_REGW, MTVEC_REGW;
  logic [`XLEN-1:0] MEDELEG_REGW, MIDELEG_REGW, SEDELEG_REGW, SIDELEG_REGW;
//  logic [11:0]     MIP_REGW, SIP_REGW, UIP_REGW, MIE_REGW, SIE_REGW, UIE_REGW;

  logic uretM, sretM, mretM, ecallM, ebreakM, wfiM, sfencevmaM;
  logic IllegalCSRAccessM;
  logic IllegalIEUInstrFaultE, IllegalIEUInstrFaultM;
  logic LoadPageFaultM, StorePageFaultM; 
  logic InstrPageFaultF, InstrPageFaultD, InstrPageFaultE, InstrPageFaultM;
  logic InstrAccessFaultF, InstrAccessFaultD, InstrAccessFaultE, InstrAccessFaultM;
  logic LoadAccessFaultM, StoreAccessFaultM;
  logic IllegalInstrFaultM;

  logic BreakpointFaultM, EcallFaultM;
  logic MTrapM, STrapM, UTrapM; 

  logic [1:0] STATUS_MPP;
  logic       STATUS_SPP, STATUS_TSR;
  logic       STATUS_MIE, STATUS_SIE;
  logic       STATUS_MPRV;
  logic [11:0] MIP_REGW, MIE_REGW;
  logic md, sd;

  logic [`XLEN-1:0] PMPADDR_ARRAY_REGW [0:15];

  logic PMASquashBusAccess, PMPSquashBusAccess;
  logic PMAInstrAccessFaultF, PMALoadAccessFaultM, PMAStoreAccessFaultM;
  logic PMPInstrAccessFaultF, PMPLoadAccessFaultM, PMPStoreAccessFaultM;

  ///////////////////////////////////////////
  // track the current privilege level
  ///////////////////////////////////////////

  // get bits of DELEG registers based on CAUSE
  assign md = CauseM[`XLEN-1] ? MIDELEG_REGW[CauseM[4:0]] : MEDELEG_REGW[CauseM[4:0]];
  assign sd = CauseM[`XLEN-1] ? SIDELEG_REGW[CauseM[4:0]] : SEDELEG_REGW[CauseM[4:0]]; // depricated
  
  // PrivilegeMode FSM
  always_comb
  /*  if      (reset) NextPrivilegeModeM = `M_MODE; // Privilege resets to 11 (Machine Mode) // moved reset to flop
    else */ if (mretM) NextPrivilegeModeM = STATUS_MPP;
    else if (sretM) NextPrivilegeModeM = {1'b0, STATUS_SPP};
    else if (uretM) NextPrivilegeModeM = `U_MODE;
    else if (TrapM) begin // Change privilege based on DELEG registers (see 3.1.8)
      if (PrivilegeModeW == `U_MODE)
        if (`N_SUPPORTED & `U_SUPPORTED & md & sd) NextPrivilegeModeM = `U_MODE;
        else if (`S_SUPPORTED & md)                NextPrivilegeModeM = `S_MODE;
        else                                       NextPrivilegeModeM = `M_MODE;
      else if (PrivilegeModeW == `S_MODE) 
        if (`S_SUPPORTED & md)                     NextPrivilegeModeM = `S_MODE;
        else                                       NextPrivilegeModeM = `M_MODE;
      else                                         NextPrivilegeModeM = `M_MODE;
    end else                                       NextPrivilegeModeM = PrivilegeModeW;

  flopenl #(2) privmodereg(clk, reset, ~StallW, NextPrivilegeModeM, `M_MODE, PrivilegeModeW);

  ///////////////////////////////////////////
  // decode privileged instructions
  ///////////////////////////////////////////

  privdec pmd(.InstrM(InstrM[31:20]), .*);

  ///////////////////////////////////////////
  // Control and Status Registers
  ///////////////////////////////////////////

  csr csr(.*);

  ///////////////////////////////////////////
  // Check physical memory accesses
  ///////////////////////////////////////////

  pmachecker pmachecker(.*);
  pmpchecker pmpchecker(.*);

  ///////////////////////////////////////////
  // Extract exceptions by name and handle them 
  ///////////////////////////////////////////

  assign BreakpointFaultM = ebreakM; // could have other causes too
  assign EcallFaultM = ecallM;
  assign ITLBFlushF = sfencevmaM;
  assign DTLBFlushM = sfencevmaM;

  // A page fault might occur because of insufficient privilege during a TLB
  // lookup or a improperly formatted page table during walking
  assign InstrPageFaultF = ITLBInstrPageFaultF || WalkerInstrPageFaultF;
  assign LoadPageFaultM = DTLBLoadPageFaultM || WalkerLoadPageFaultM;
  assign StorePageFaultM = DTLBStorePageFaultM || WalkerStorePageFaultM;

  assign InstrAccessFaultF = PMAInstrAccessFaultF || PMPInstrAccessFaultF;
  assign LoadAccessFaultM  = PMALoadAccessFaultM || PMPLoadAccessFaultM;
  assign StoreAccessFaultM  = PMAStoreAccessFaultM || PMPStoreAccessFaultM;

  assign SquashBusAccess = PMASquashBusAccess || PMPSquashBusAccess;

  // pipeline fault signals
  flopenrc #(2) faultregD(clk, reset, FlushD, ~StallD,
                  {InstrPageFaultF, InstrAccessFaultF},
                  {InstrPageFaultD, InstrAccessFaultD});
  flopenrc #(3) faultregE(clk, reset, FlushE, ~StallE,
                  {IllegalIEUInstrFaultD, InstrPageFaultD, InstrAccessFaultD}, // ** vs IllegalInstrFaultInD
                  {IllegalIEUInstrFaultE, InstrPageFaultE, InstrAccessFaultE});
  flopenrc #(3) faultregM(clk, reset, FlushM, ~StallM,
                  {IllegalIEUInstrFaultE, InstrPageFaultE, InstrAccessFaultE},
                  {IllegalIEUInstrFaultM, InstrPageFaultM, InstrAccessFaultM});

  trap trap(.*);

endmodule




