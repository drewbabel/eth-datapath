set part    xc7a200tsbg484-1
set root    [file normalize [file join [file dirname [info script]] ..]]
set outdir  [file join $root vivado build nv]
set srcdir  [file join $outdir src]
file delete -force $srcdir
file mkdir $outdir
file mkdir $srcdir

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

set own {}
foreach f [lsort [glob [file join $root rtl *.sv]]] {
  lappend own [stripped_copy $f $srcdir]
}
foreach f [lsort [glob [file join $root lib uart rtl *.sv]]] {
  lappend own [stripped_copy $f $srcdir]
}
lappend own [stripped_copy [file join $root boards nexys_video board_top.sv] $srcdir]

create_project -in_memory -part $part

set ethdir  [file join $root lib eth rtl]
set axisdir [file join $root lib eth lib axis rtl]

set vendored {}
foreach f {iddr oddr ssio_ddr_in ssio_ddr_out rgmii_phy_if eth_mac_1g_rgmii_fifo
           eth_mac_1g_rgmii eth_mac_1g axis_gmii_rx axis_gmii_tx lfsr} {
  lappend vendored [file join $ethdir $f.v]
}
foreach f {axis_fifo axis_async_fifo axis_async_fifo_adapter sync_reset} {
  lappend vendored [file join $axisdir $f.v]
}

read_verilog -sv $own
read_verilog $vendored
read_xdc [file join $root boards nexys_video nexys_video.xdc]

synth_design -top board_top -part $part

set fwd [get_pins -hier -filter {NAME =~ *rgmii_phy_if_inst/clk_oddr_inst/*oddr_inst/D*}]
puts "RESULT clock_forward_pins [llength $fwd]"
if {[llength $fwd] > 0} {
  set_multicycle_path 2 -setup -to $fwd
  set_multicycle_path 1 -hold  -to $fwd
}

opt_design -directive Explore
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
phys_opt_design -directive AggressiveExplore

write_checkpoint -force  [file join $outdir board_top_routed.dcp]
report_utilization -file [file join $outdir utilization.rpt]
report_timing_summary -file [file join $outdir timing_summary.rpt]
report_timing -delay_type max -max_paths 10 -file [file join $outdir worst_path.rpt]
report_utilization -hierarchical -hierarchical_depth 3 -hierarchical_min_primitive_count 1 \
                   -file [file join $outdir hier_util.rpt]

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts [format "RESULT wns_ns %.3f" $wns]
puts [format "RESULT whs_ns %.3f" $whs]
if {$wns < 0 || $whs < 0} {
  puts "RESULT timing FAILED"
} else {
  puts "RESULT timing MET"
}

write_bitstream -force [file join $outdir board_top.bit]
