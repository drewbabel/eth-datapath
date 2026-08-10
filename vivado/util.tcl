set root     [file normalize [file join [file dirname [info script]] ..]]
set mod      [lindex $argv 0]
set part     xc7a35tcpg236-1
set outdir   [file join $root vivado_out $mod]
set synthdir [file join $root vivado_out rtl_synth]
file mkdir $outdir
file mkdir $synthdir

proc count_cells {pattern} {
  if {[catch {llength [get_cells -hier -quiet -filter "REF_NAME =~ $pattern"]} n]} { return -1 }
  return $n
}

proc count_bits {pattern bits} {
  set n [count_cells $pattern]
  if {$n < 0} { return 0 }
  return [expr {$n * $bits}]
}

# Strips default_nettype
proc stripped_copy {src dstdir} {
  set in  [open $src r]
  set out [open [file join $dstdir [file tail $src]] w]
  while {[gets $in line] >= 0} {
    if {![string match {`default_nettype*} $line]} { puts $out $line }
  }
  close $in
  close $out
  return [file join $dstdir [file tail $src]]
}

set pkgs {}
set rest {}
foreach f [lsort [glob [file join $root rtl *.sv]]] {
  set copy [stripped_copy $f $synthdir]
  if {[string match *_pkg [file rootname [file tail $f]]]} { lappend pkgs $copy } else { lappend rest $copy }
}
if {[llength $pkgs]} { read_verilog -sv $pkgs }
read_verilog -sv $rest

synth_design -top $mod -part $part -mode out_of_context -flatten_hierarchy full

report_utilization -file [file join $outdir utilization.rpt]
write_checkpoint -force [file join $outdir post_synth.dcp]

set luts [count_cells "LUT*"]
set ffs  [count_cells "FD*"]

set dbits 0
incr dbits [count_bits "RAM32X1S"  32]
incr dbits [count_bits "RAM32X1D"  32]
incr dbits [count_bits "RAM32M"    256]
incr dbits [count_bits "RAM64X1S"  64]
incr dbits [count_bits "RAM64X1D"  64]
incr dbits [count_bits "RAM64M"    256]
incr dbits [count_bits "RAM128X1S" 128]
incr dbits [count_bits "RAM128X1D" 128]
incr dbits [count_bits "RAM256X1S" 256]

set fh [open [file join $outdir util.txt] w]
puts $fh "module $mod"
puts $fh [format "luts %d" $luts]
puts $fh [format "flipflops %d" $ffs]
puts $fh [format "distributed_ram_bits %d" $dbits]
close $fh
puts [format "RESULT %s luts=%d ff=%d dbits=%d" $mod $luts $ffs $dbits]
