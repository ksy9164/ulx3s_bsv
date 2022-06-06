import Clocks :: *;
import Vector::*;
import FIFO::*;
import BRAM::*;
import BRAMFIFO::*;
import Uart::*;
import Sdram::*;

interface HwMainIfc;
	method ActionValue#(Bit#(8)) serial_tx;
	method Action serial_rx(Bit#(8) rx);
endinterface

module mkHwMain#(Ulx3sSdramUserIfc mem) (HwMainIfc);
	Clock curclk <- exposeCurrentClock;
	Reset currst <- exposeCurrentReset;

	Reg#(Bit#(32)) cycles <- mkReg(0);
	Reg#(Bit#(32)) cycleOutputStart <- mkReg(0);
	rule incCyclecount;
		cycles <= cycles + 1;
	endrule

	Reg#(Bit#(32)) cycleBegin <- mkReg(0);

	FIFO#(Bit#(8)) serialrxQ <- mkFIFO;
	FIFO#(Bit#(8)) serialtxQ <- mkFIFO;

	Vector#(2, FIFO#(Bit#(8))) r_bufQ <- replicateM(mkSizedBRAMFIFO(1024));
	Vector#(2, FIFO#(Bit#(8))) c_bufQ <- replicateM(mkSizedBRAMFIFO(1024));

	//Vector#(2, FIFO#(Bit#(8))) r_bufQ <- replicateM(mkFIFO);
	//Vector#(2, FIFO#(Bit#(8))) c_bufQ <- replicateM(mkFIFO);

	Vector#(2, FIFO#(Bit#(8))) r_resQ <- replicateM(mkFIFO);
	Vector#(2, FIFO#(Bit#(8))) c_resQ <- replicateM(mkFIFO);

	//Vector#(2, FIFO#(Bit#(8))) merge_Q <- replicateM(mkSizedBRAMFIFO(512));
	Vector#(2, FIFO#(Bit#(8))) merge_Q <- replicateM(mkFIFO);

	Vector#(2,Reg#(Bit#(32))) r_cnt <- replicateM(mkReg(0));
	Vector#(2,Reg#(Bit#(32))) c_cnt <- replicateM(mkReg(0));
	Reg#(Bit#(32)) res_r_cnt <- mkReg(0);
	Reg#(Bit#(32)) res_c_cnt <- mkReg(0);

	FIFO#(Bit#(8)) r_startQ <- mkFIFO;
	FIFO#(Bit#(8)) c_startQ <- mkFIFO;

	//FIFO#(Bit#(8)) r_startQ <- replicateM(mkSizedBRAMFIFO(1024));
	//FIFO#(Bit#(8)) c_startQ <- replicateM(mkSizedBRAMFIFO(1024));
	
	Vector#(2,Reg#(Bit#(32))) q_cnt <- replicateM(mkReg(0));

	rule relayStart;
		serialrxQ.deq;
		let pix = serialrxQ.first;
		
		r_startQ.enq(pix);
		c_startQ.enq(pix);
		
	endrule

	rule row_run;
		r_startQ.deq;
		let d = r_startQ.first;

		r_bufQ[0].enq(d * -1);
		r_bufQ[1].enq(d);
	endrule

	rule row_manage_upper;
		r_cnt[0] <= r_cnt[0] + 1;
		if (r_cnt[0] / 512 == 0) begin
			r_resQ[0].enq(0);
		end else if (r_cnt[0] / 512 != 256) begin
			r_bufQ[0].deq;
			r_resQ[0].enq(r_bufQ[0].first);
		end
	endrule
	rule row_manage_lower;
		r_cnt[1] <= r_cnt[1] + 1;
		if (r_cnt[1] / 512 == 0) begin
			r_bufQ[1].deq;
		end else if (r_cnt[0] / 512 != 256) begin
			r_bufQ[1].deq;
			r_resQ[1].enq(r_bufQ[1].first);
		end else begin
			r_resQ[1].enq(0);
		end
	endrule
	rule row_res;
		r_resQ[0].deq;
		r_resQ[1].deq;
		let d1 = r_resQ[0].first;
		let d2 = r_resQ[1].first;
		merge_Q[0].enq(d1 + d2);
		//q_cnt[0] <= q_cnt[0] + 1;
	endrule


	rule col_run;
		c_startQ.deq;
		let d = c_startQ.first;

		c_bufQ[0].enq(d * -1);
		c_bufQ[1].enq(d);
	endrule
	rule col_manage_left;
	/*	c_cnt[0] <= c_cnt[0] + 1;
		if (c_cnt[0] % 513 == 0) begin
			c_resQ[0].enq(0);
		end else if (c_cnt[0] % 513 != 512) begin
			c_bufQ[0].deq;
			c_resQ[0].enq(c_bufQ[0].first);
		end else begin
			c_bufQ[0].deq;
		end */
			c_bufQ[0].deq;
			c_resQ[0].enq(c_bufQ[0].first);
	endrule
	rule col_manage_right;
		c_cnt[1] <= c_cnt[1] + 1;
/*
		if (c_cnt[1] % 513 == 0) begin
			c_bufQ[1].deq;
		end else if (c_cnt[1] % 513 != 512) begin
			c_bufQ[1].deq;
			c_resQ[1].enq(c_bufQ[1].first);
		end else begin
			c_resQ[1].enq(0);
		end
*/
			c_bufQ[1].deq;
			c_resQ[1].enq(c_bufQ[1].first);
	endrule
	rule col_res;
		c_resQ[0].deq;
		c_resQ[1].deq;
		let d1 = c_resQ[0].first;
		let d2 = c_resQ[1].first;
		merge_Q[1].enq(d1 + d2);
	endrule

	Reg#(Bit#(32)) qc <- mkReg(0);
	rule merge;
		merge_Q[0].deq;
		merge_Q[1].deq;
		//serialtxQ.enq((merge_Q[0].first + merge_Q[1].first) / 2);
		qc <= qc + 1;
		//$display("Cycle %d ", qc);
	endrule

	Reg#(Bit#(32)) pixOutCnt <- mkReg(0);
	method ActionValue#(Bit#(8)) serial_tx;
		if ( cycleOutputStart == 0 ) begin
			$write( "Impage processing latency: %d cycles\n", cycles - cycleBegin );
			cycleOutputStart <= cycles;
		end
		if ( pixOutCnt + 1 >= 512*256 ) begin
			$write( "Impage processing total cycles: %d\n", cycles - cycleBegin );
		end
		pixOutCnt <= pixOutCnt + 1;
		serialtxQ.deq;
		return serialtxQ.first();
	endmethod
	method Action serial_rx(Bit#(8) d);
		if ( cycleBegin == 0 ) cycleBegin <= cycles;
		serialrxQ.enq(d);
	endmethod
endmodule
