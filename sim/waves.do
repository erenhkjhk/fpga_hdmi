# Use after loading a testbench in the ModelSim GUI. Avoid logging large arrays.
view wave
foreach signal [find signals sim:/*/*] {
    if {[regexp {(clk|rst|rst_n|valid|ready|data|addr|_x|_y|alpha|pixels|fault|underflow|user|last|state|left|right|cts|_n|used|usedw|we|re)$} $signal]} {
        add wave $signal
    }
}
foreach pattern {sim:/*/dut/state sim:/*/dut/fade_alpha sim:/*/dut/selected_alpha sim:/*/dut/transition_active} {
    foreach signal [find signals $pattern] {add wave $signal}
}
configure wave -timelineunits us
