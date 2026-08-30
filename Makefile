.PHONY: help test self-test benchmark

help:
	@echo "make test       Run unit and dashboard tests"
	@echo "make self-test  Run the synthetic-IQ DSP/squelch check"
	@echo "make benchmark  Measure maximum DSP realtime factor"

test:
	python3 -m unittest tests.test_web_dashboard

self-test:
	./frs_all_channels.py --self-test

benchmark:
	./frs_all_channels.py --benchmark-dsp --run-seconds 20
