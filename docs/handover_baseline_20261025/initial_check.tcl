set task_root [file normalize [pwd]]
import_device eagle_s20.db -package EG4S20BG256
open_project -single_run $task_root/project1.al
elaborate -top fpga_hdmi_top
read_adc $task_root/constraints/hx4s20_hdmi_b.adc
optimize_rtl
export_db $task_root/tmp/td_registration/project1_rtl.db
read_sdc $task_root/constraints/fpga_hdmi_top.sdc
read_sdc -ip fifo_pixel_async $task_root/al_ip/fifo_pixel_async/fifo_pixel_async.tcl
optimize_gate
legalize_phy_inst
read_sdc $task_root/constraints/fpga_hdmi_top.sdc
read_sdc -ip fifo_pixel_async $task_root/al_ip/fifo_pixel_async/fifo_pixel_async.tcl
update_timing
puts "CONSTRAINT_PORTS [get_ports *]"
puts "CONSTRAINT_CLOCKS [get_clocks *]"
report_clock_summary -file $task_root/tmp/td_registration/clocks.rpt
report_area -file $task_root/tmp/td_registration/area.rpt
report_timing_summary -file $task_root/tmp/td_registration/timing.rpt
export_db $task_root/tmp/td_registration/project1_gate.db
puts "TD_REGISTRATION_GATE_DONE"
close_project
exit
