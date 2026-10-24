# Run within a macro so onerror/onbreak are effective in ModelSim 2020.1.
# The Python runner additionally requires the testbench PASS marker.
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
onfinish exit
if {[info exists capture_waves] && $capture_waves} {
    foreach signal [find signals sim:/*/*] {
        if {[regexp {(clk|rst|rst_n|valid|ready|data|addr|_x|_y|alpha|pixels|fault|underflow|user|last|state|left|right|cts|_n|used|usedw|we|re)$} $signal]} {
            log $signal
        }
    }
    foreach pattern {sim:/*/dut/state sim:/*/dut/fade_alpha sim:/*/dut/selected_alpha sim:/*/dut/transition_active} {
        foreach signal [find signals $pattern] {log $signal}
    }
}
run -all
quit -code 0 -force
