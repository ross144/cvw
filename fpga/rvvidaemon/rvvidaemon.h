#ifndef __RVVIDAEMON_H
#define __RVVIDAEMON_H

#include <stdint.h>

typedef struct __attribute__((packed)) {
  uint16_t CSRReg : 12;
  uint16_t CSRPad : 4;
  uint64_t CSRValue;
} CSR_t;

typedef struct __attribute__((packed)) {
  uint64_t PC;
  uint32_t insn;
  uint64_t Mcycle;
  uint64_t Minstret;
  uint8_t Trap : 1;
  uint8_t PrivilegeMode : 2;
  uint8_t GPREn : 1;
  uint8_t FPREn : 1;
  uint8_t Pad3: 3;
  uint16_t CSRCount : 12;
  uint16_t Pad4 : 4;
  uint8_t GPRReg : 5;
  uint8_t PadG3 : 3;
  uint64_t GPRValue;
  uint8_t FPRReg : 5;
  uint8_t PadF3 : 3;
  uint64_t FPRValue;
  CSR_t CSR[3];
} RequiredRVVI_t; // 904 bits

#endif
