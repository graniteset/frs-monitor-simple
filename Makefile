.PHONY: help test self-test benchmark fpga-test

help:
	@echo "make test       Run unit and dashboard tests"
	@echo "make self-test  Run the synthetic-IQ DSP/squelch check"
	@echo "make benchmark  Measure maximum DSP realtime factor"
	@echo "make fpga-test  Simulate board-independent FPGA source/mux and receiver DSP (Icarus Verilog)"

test:
	python3 -m unittest tests.test_web_dashboard

self-test:
	./frs_all_channels.py --self-test

benchmark:
	./frs_all_channels.py --benchmark-dsp --run-seconds 20

fpga-test:
	iverilog -g2012 -s tb_iq_stream -o /tmp/frs_tb_iq_stream fpga/iq_test_source.sv fpga/axis_iq_mux.sv fpga/tb_iq_stream.sv
	vvp /tmp/frs_tb_iq_stream
	iverilog -g2012 -s tb_frs_plutosky_r2_stream -o /tmp/frs_tb_plutosky_r2_stream fpga/iq_test_source.sv fpga/axis_iq_mux.sv fpga/plutosky_r2/frs_plutosky_r2_stream.sv fpga/plutosky_r2/tb_frs_plutosky_r2_stream.sv
	vvp /tmp/frs_tb_plutosky_r2_stream
	iverilog -g2012 -s tb_band_ddc -o /tmp/frs_tb_band_ddc fpga/band_ddc_decimator.sv fpga/tb_band_ddc.sv
	vvp /tmp/frs_tb_band_ddc
	iverilog -g2012 -s tb_band_ddc -Ptb_band_ddc.BAND2=1 -o /tmp/frs_tb_band_ddc2 fpga/band_ddc_decimator.sv fpga/tb_band_ddc.sv
	vvp /tmp/frs_tb_band_ddc2
	iverilog -g2012 -s tb_sparse_channelizer -o /tmp/frs_tb_sparse_channelizer fpga/sparse_channelizer.sv fpga/tb_sparse_channelizer.sv
	vvp /tmp/frs_tb_sparse_channelizer
	iverilog -g2012 -s tb_complex_squelch -o /tmp/frs_tb_complex_squelch fpga/complex_squelch.sv fpga/tb_complex_squelch.sv
	vvp /tmp/frs_tb_complex_squelch
	iverilog -g2012 -s tb_quadrature_demod -o /tmp/frs_tb_quadrature_demod fpga/quadrature_demod.sv fpga/tb_quadrature_demod.sv
	vvp /tmp/frs_tb_quadrature_demod
	iverilog -g2012 -s tb_fm_deemphasis -o /tmp/frs_tb_fm_deemphasis fpga/fm_deemphasis.sv fpga/tb_fm_deemphasis.sv
	vvp /tmp/frs_tb_fm_deemphasis
	iverilog -g2012 -s tb_audio_fir_decimator -o /tmp/frs_tb_audio_fir_decimator fpga/audio_fir_decimator.sv fpga/tb_audio_fir_decimator.sv
	vvp /tmp/frs_tb_audio_fir_decimator
	iverilog -g2012 -s tb_frs_channel_audio -o /tmp/frs_tb_frs_channel_audio fpga/complex_squelch.sv fpga/quadrature_demod.sv fpga/fm_deemphasis.sv fpga/audio_fir_decimator.sv fpga/frs_channel_audio.sv fpga/tb_frs_channel_audio.sv
	vvp /tmp/frs_tb_frs_channel_audio
	iverilog -g2012 -s tb_axis_rr_merge2_iq -o /tmp/frs_tb_axis_rr_merge2_iq fpga/axis_rr_merge2_iq.sv fpga/tb_axis_rr_merge2_iq.sv
	vvp /tmp/frs_tb_axis_rr_merge2_iq
	iverilog -g2012 -s tb_frs_multi_channel_audio -o /tmp/frs_tb_frs_multi_channel_audio fpga/frs_multi_channel_audio.sv fpga/tb_frs_multi_channel_audio.sv
	vvp /tmp/frs_tb_frs_multi_channel_audio
	iverilog -g2012 -s tb_frs_receive_core -o /tmp/frs_tb_frs_receive_core fpga/band_ddc_decimator.sv fpga/sparse_channelizer.sv fpga/axis_rr_merge2_iq.sv fpga/frs_multi_channel_audio.sv fpga/frs_receive_core.sv fpga/tb_frs_receive_core.sv
	vvp /tmp/frs_tb_frs_receive_core
	iverilog -g2012 -s tb_frs_receive_bursts -o /tmp/frs_tb_frs_receive_bursts fpga/band_ddc_decimator.sv fpga/sparse_channelizer.sv fpga/axis_rr_merge2_iq.sv fpga/frs_multi_channel_audio.sv fpga/frs_receive_core.sv fpga/tb_frs_receive_bursts.sv
	vvp /tmp/frs_tb_frs_receive_bursts
	iverilog -g2012 -s tb_frs_receive_6p4 -o /tmp/frs_tb_frs_receive_6p4 fpga/band_ddc_decimator.sv fpga/sparse_channelizer.sv fpga/axis_rr_merge2_iq.sv fpga/frs_multi_channel_audio.sv fpga/frs_receive_core.sv fpga/tb_frs_receive_bursts.sv fpga/tb_frs_receive_6p4.sv
	vvp /tmp/frs_tb_frs_receive_6p4
	iverilog -g2012 -s tb_frs_receive_overrun -o /tmp/frs_tb_frs_receive_overrun fpga/band_ddc_decimator.sv fpga/sparse_channelizer.sv fpga/axis_rr_merge2_iq.sv fpga/frs_multi_channel_audio.sv fpga/frs_receive_core.sv fpga/tb_frs_receive_overrun.sv
	vvp /tmp/frs_tb_frs_receive_overrun
	iverilog -g2012 -s frs_receive_core -o /tmp/frs_receive_core fpga/band_ddc_decimator.sv fpga/sparse_channelizer.sv fpga/axis_rr_merge2_iq.sv fpga/frs_multi_channel_audio.sv fpga/frs_receive_core.sv
