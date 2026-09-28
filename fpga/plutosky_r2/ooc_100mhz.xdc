# Core-clock target for the first utilization/timing estimate. The PlutoSky
# BD's actual `axi_ad9361/l_clk` source and constraints must be verified in its
# generated project before this period is treated as a board constraint.
create_clock -name frs_core_clk -period 10.000 [get_ports aclk]
