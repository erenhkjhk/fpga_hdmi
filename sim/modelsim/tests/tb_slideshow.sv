`timescale 1ns/1ps
module tb_slideshow;
 reg clk=0;always #10 clk=~clk;reg rst=1,tick=0,prev=0,next=0,auto_key=0;
 wire ov,ds,dc,finish,finish_abort,result_ready,autoplay,busy,error;wire [15:0] oi,current;
 reg fd=0,dd=0,complete=0,iv=0,result=0;
 slideshow_control #(.AUTO_INTERVAL_MS(5),.AUTO_DEFAULT(0)) dut(
 .clk(clk),.rst(rst),.tick_ms(tick),.previous_press(prev),.next_press(next),.auto_press(auto_key),
 .memory_ready(1'b1),.memory_fault(1'b0),.mount_done(1'b1),.catalog_ready(1'b1),.image_count(16'd3),.storage_error(1'b0),
 .open_valid(ov),.open_ready(1'b1),.open_index(oi),.file_done(fd),.decoder_start(ds),.decoder_cancel(dc),
 .decoder_done(dd),.decoder_complete(complete),.decoder_error(1'b0),.image_begin_valid(iv),.image_begin_ready(1'b1),
 .finish_valid(finish),.finish_ready(1'b1),.finish_abort(finish_abort),.result_valid(result),.result_ready(result_ready),.result_abort(1'b0),
 .auto_enabled(autoplay),.busy(busy),.error(error),.current_index(current));
 task file_complete;
  wait(ds);@(negedge clk);iv=1;@(negedge clk);iv=0;fd=1;dd=1;complete=1;
  @(negedge clk);fd=0;wait(finish);@(negedge clk);wait(result_ready);
 endtask
 task commit;
  @(negedge clk);result=1;@(negedge clk);result=0;dd=0;complete=0;
 endtask
 initial begin
  #100;@(negedge clk);rst=0;file_complete();
  repeat(10) begin @(negedge clk);tick=1;end
  if(!busy || ov) $fatal(1,"Job released before transition result");tick=0;commit();
  repeat(4) @(negedge clk);if(current!=0 || busy) $fatal(1,"First photo commit");
  next=1;@(negedge clk);next=0;wait(ov);if(oi!=1) $fatal(1,"Next index");file_complete();
  prev=1;@(negedge clk);prev=0;next=1;@(negedge clk);next=0;prev=1;@(negedge clk);prev=0;
  repeat(20) @(negedge clk);if(ov) $fatal(1,"Third image opened during transition");commit();
  wait(ov);if(oi!=0) $fatal(1,"Latest pending direction");file_complete();commit();
  repeat(3) @(negedge clk);auto_key=1;@(negedge clk);auto_key=0;
  repeat(4) begin tick=1;@(negedge clk);end
  if(ov) $fatal(1,"Auto dwell too short");tick=1;@(negedge clk);tick=0;
  wait(ov);if(oi!=1 || !autoplay) $fatal(1,"Auto dwell/index");
  $display("PASS: tb_slideshow pending key direction, transition lock, auto dwell after commit");$finish;
 end
 initial begin #100000;$fatal(1,"slideshow timeout state=%0d",dut.state);end
endmodule
