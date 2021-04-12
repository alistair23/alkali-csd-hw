/*
 * Copyright (c) 2021 Antmicro <www.antmicro.com>
 *
 * SPDX-License-Identifier: Apache-2.0
 */

package NVMeCore

import NVMeCore.Bus.AXI4Lite
import NVMeCore.CSR.{CSR, CSRBusBundle}
import chisel3._
import chisel3.util._

class AXI4LiteCSR(addrWidth : Int, dataWidth : Int) extends Module{
  val io = IO(new Bundle{
    val ctl = Flipped(new AXI4Lite(addrWidth, controlDataWidth))
    val bus = new CSRBusBundle
  })

  val sIdle :: sReadAddr :: sReadData :: sWriteAddr :: sWriteData :: sWriteResp :: Nil = Enum(6)
  val state = RegInit(sIdle)

  val awready = RegInit(false.B)
  val wready = RegInit(false.B)
  val bvalid = RegInit(false.B)
  val bresp = WireInit(0.U(AXI4Lite.respWidth.W))

  val arready = RegInit(false.B)
  val rvalid = RegInit(false.B)
  val rresp = WireInit(0.U(AXI4Lite.respWidth.W))

  val addr = RegInit(0.U(addrWidth.W))

  io.ctl.r.rdata := io.bus.dataIn
  io.bus.dataOut := io.ctl.w.wdata

  io.ctl.aw.awready := awready
  io.ctl.w.wready := wready
  io.ctl.b.bvalid := bvalid
  io.ctl.b.bresp := bresp

  io.ctl.ar.arready := arready
  io.ctl.r.rvalid := rvalid
  io.ctl.r.rresp := rresp

  io.bus.read := io.ctl.r.rready && rvalid
  io.bus.write := io.ctl.w.wvalid && wready
  io.bus.addr := addr

  switch(state){
    is(sIdle){
      when(io.ctl.aw.awvalid){
        state := sWriteAddr
        addr := io.ctl.aw.awaddr(5, 2)
        awready := true.B

      }.elsewhen(io.ctl.ar.arvalid){
        state := sReadAddr
        addr := io.ctl.ar.araddr(5, 2)
        arready := true.B
      }
    }
    is(sReadAddr){
      when(io.ctl.ar.arvalid && arready){
        state := sReadData
        arready := false.B
        rvalid := true.B
      }
    }
    is(sReadData){
      when(io.ctl.r.rready && rvalid){
        state := sIdle
        rvalid := false.B
      }
    }
    is(sWriteAddr){
      when(io.ctl.aw.awvalid && awready){
        state := sWriteData
        awready := false.B
        wready := true.B
      }
    }
    is(sWriteData){
      when(io.ctl.w.wvalid && wready){
        state := sWriteResp
        wready := false.B
        bvalid := true.B
      }
    }
    is(sWriteResp){
      when(io.ctl.b.bready && bvalid){
        state := sIdle
        bvalid := false.B
      }
    }
  }
}