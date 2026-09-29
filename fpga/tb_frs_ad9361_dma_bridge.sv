`timescale 1ns/1ps
module tb_frs_ad9361_dma_bridge;
    reg dsp_clk = 1'b0;
    reg adc_clk = 1'b0;
    always #5 dsp_clk = ~dsp_clk;
    always #2 adc_clk = ~adc_clk;

    reg resetn = 1'b0;
    reg xfer_req = 1'b1;
    reg overflow_model = 1'b0;
    wire fifo_wr_en;
    wire [63:0] fifo_wr_din;
    wire fifo_wr_sync;
    wire rx_fifo_overrun;
    wire overflow_seen;
    wire pair_mismatch_seen;
    wire band1_overrun;
    wire band2_overrun;
    wire invalid_channel;
    integer dma_words = 0;
    integer dma_dump_fd = 0;
    integer dma_dump_words = 0;
    reg dma_dump_enabled = 1'b0;
    string dma_dump_path;
    integer attempted_words = 0;
    integer rejected_words = 0;
    integer retried_words = 0;
    integer accepted_iq_samples = 0;
    integer active1_count = 0;
    integer quiet_count = 0;
    integer active2_count = 0;
    reg [63:0] active1_energy = 0;
    reg [63:0] quiet_energy = 0;
    reg [63:0] active2_energy = 0;
    reg [63:0] active1_other_energy = 0;
    reg [63:0] active2_other_energy = 0;
    integer active1_tag4_count = 0;
    integer active2_tag4_count = 0;
    reg [63:0] active1_channel_energy [0:22];
    reg [63:0] active2_channel_energy [0:22];
    reg [63:0] active1_pfb_energy [0:22];
    integer active1_pfb_count [0:22];
    reg retry_expected = 1'b0;
    reg [63:0] rejected_word;
    reg [4:0] channel0;
    reg [4:0] channel1;

    // Observe the channelizer's complex outputs before FM demodulation. With
    // squelch forced open for this deterministic source, even tiny adjacent
    // filter leakage can turn into high-looking noise after phase
    // discrimination; PCM RMS alone is therefore not a valid isolation test.
    wire [36:0] pfb_data = dut.receive_path.band1_channel_data;
    wire pfb_valid = dut.receive_path.band1_channel_valid;
    wire pfb_ready = dut.receive_path.band1_channel_ready;

    frs_ad9361_dma_bridge #(
        .TEST_MODE(1),
        .TEST_ON_SAMPLES(38_400), // 6 ms, enough for DSP and audio FIR settling
        .TEST_OFF_SAMPLES(51_200) // 8 ms gap to prove clean close and recovery
    ) dut (
        .adc_clk(adc_clk), .adc_resetn(resetn),
        .dsp_clk(dsp_clk), .dsp_resetn(resetn),
        .adc0_word(16'd0), .adc1_word(16'd0),
        .valid0(1'b0), .valid1(1'b0),
        .enable0(1'b0), .enable1(1'b0),
        .fifo_wr_en(fifo_wr_en), .fifo_wr_din(fifo_wr_din),
        .fifo_wr_overflow(overflow_model), .fifo_wr_sync(fifo_wr_sync),
        .fifo_wr_xfer_req(xfer_req),
        .rx_fifo_overrun(rx_fifo_overrun),
        .status_overflow_seen(overflow_seen),
        .pair_mismatch_seen(pair_mismatch_seen),
        .band1_overrun(band1_overrun), .band2_overrun(band2_overrun),
        .invalid_channel(invalid_channel)
    );

    always @(posedge dsp_clk) begin
        // Model ADI src_fifo_inf: EN is sampled into its internal ready FIFO,
        // and OVERFLOW reports a rejected EN beat one clock later. Force the
        // first request and then periodic requests to encounter backpressure.
        if (!resetn) begin
            overflow_model <= 1'b0;
            attempted_words = 0;
            rejected_words = 0;
            retried_words = 0;
            retry_expected = 1'b0;
            accepted_iq_samples = 0;
            active1_count = 0;
            quiet_count = 0;
            active2_count = 0;
            active1_energy = 0;
            quiet_energy = 0;
            active2_energy = 0;
            active1_other_energy = 0;
            active2_other_energy = 0;
            active1_tag4_count = 0;
            active2_tag4_count = 0;
            for (integer clear_ch = 0; clear_ch <= 22; clear_ch = clear_ch + 1) begin
                active1_pfb_energy[clear_ch] = 0;
                active1_pfb_count[clear_ch] = 0;
            end
        end else if (fifo_wr_en) begin
            if (retry_expected && fifo_wr_din !== rejected_word)
                $fatal(1, "DMA retry changed data: expected %h, got %h",
                       rejected_word, fifo_wr_din);
            if (dma_dump_enabled) begin
                // The dump mode models an always-ready DMA sink. Store the
                // exact eight bytes presented by the RTL bridge, in CPU/DMA
                // little-endian order, for the Go ingest/web integration test.
                overflow_model <= 1'b0;
                for (integer byte_index = 0; byte_index < 8; byte_index = byte_index + 1)
                    $fwrite(dma_dump_fd, "%c", fifo_wr_din[byte_index*8 +: 8]);
                dma_dump_words = dma_dump_words + 1;
            end else if (attempted_words == 0 || (attempted_words % 11) == 4) begin
                overflow_model <= 1'b1;
                rejected_word = fifo_wr_din;
                rejected_words = rejected_words + 1;
                retry_expected = 1'b1;
            end else begin
                overflow_model <= 1'b0;
                if (retry_expected) begin
                    retried_words = retried_words + 1;
                    retry_expected = 1'b0;
                end
            end
            attempted_words = attempted_words + 1;
        end else begin
            overflow_model <= 1'b0;
        end

        if (resetn && dut.selected_valid && dut.selected_ready)
            accepted_iq_samples = accepted_iq_samples + 1;

        // Bound adjacent-channel leakage directly in the PFB complex domain.
        // The selected window excludes startup and the source burst edges.
        if (resetn && pfb_valid && pfb_ready && accepted_iq_samples >= 32_000 &&
            accepted_iq_samples < 38_000) begin
            pfb_energy(pfb_data[36:32], pfb_data[31:16], pfb_data[15:0]);
        end

        if (resetn && fifo_wr_en) begin
            channel0 = fifo_wr_din[20:16];
            channel1 = fifo_wr_din[41:37];
            if (fifo_wr_din[63:62] !== 2'b10 || fifo_wr_din[61:42] !== 20'd0)
                $fatal(1, "invalid packed DMA record header: %h", fifo_wr_din);
            if (channel0 < 1 || channel0 > 22 || channel1 < 1 || channel1 > 22)
                $fatal(1, "invalid channel tags in DMA record: %0d, %0d", channel0, channel1);
            dma_words = dma_words + 1;

            // Classify settled audio on either side of a long synthetic burst
            // and inside its following gap. Windows include DMA/pipeline delay.
            sample_energy(channel0, fifo_wr_din[15:0]);
            sample_energy(channel1, fifo_wr_din[36:21]);
        end
        if (resetn && (rx_fifo_overrun || pair_mismatch_seen || band1_overrun ||
                       band2_overrun || invalid_channel))
            $fatal(1, "bridge reported an overrun or invalid channel");
    end

    task pfb_energy;
        input [4:0] tag;
        input [15:0] i_bits;
        input [15:0] q_bits;
        integer signed i_value;
        integer signed q_value;
        reg [63:0] energy;
        begin
            i_value = $signed(i_bits);
            q_value = $signed(q_bits);
            energy = 64'(i_value * i_value) + 64'(q_value * q_value);
            active1_pfb_energy[tag] = active1_pfb_energy[tag] + energy;
            active1_pfb_count[tag] = active1_pfb_count[tag] + 1;
        end
    endtask

    task sample_energy;
        input [4:0] tag;
        input [15:0] sample_bits;
        integer signed sample_value;
        reg [31:0] energy;
        begin
            sample_value = $signed(sample_bits);
            energy = sample_value * sample_value;
            if (accepted_iq_samples >= 32_000 && accepted_iq_samples < 38_000) begin
                active1_channel_energy[tag] = active1_channel_energy[tag] + energy;
                if (tag == 5'd4) begin
                    active1_count = active1_count + 1;
                    active1_energy = active1_energy + energy;
                    active1_tag4_count = active1_tag4_count + 1;
                end else begin
                    active1_other_energy = active1_other_energy + energy;
                end
            end else if (accepted_iq_samples >= 90_000 && accepted_iq_samples < 102_000) begin
                if (tag == 5'd4) begin
                    quiet_count = quiet_count + 1;
                    quiet_energy = quiet_energy + energy;
                end
            end else if (accepted_iq_samples >= 120_000 && accepted_iq_samples < 126_000) begin
                active2_channel_energy[tag] = active2_channel_energy[tag] + energy;
                if (tag == 5'd4) begin
                    active2_count = active2_count + 1;
                    active2_energy = active2_energy + energy;
                    active2_tag4_count = active2_tag4_count + 1;
                end else begin
                    active2_other_energy = active2_other_energy + energy;
                end
            end
        end
    endtask

    initial begin
        if ($value$plusargs("DMA_DUMP=%s", dma_dump_path)) begin
            dma_dump_fd = $fopen(dma_dump_path, "wb");
            if (dma_dump_fd == 0)
                $fatal(1, "could not open DMA dump path %s", dma_dump_path);
            dma_dump_enabled = 1'b1;
        end
        for (integer init_ch = 0; init_ch <= 22; init_ch = init_ch + 1) begin
            active1_channel_energy[init_ch] = 0;
            active2_channel_energy[init_ch] = 0;
        end
        repeat (6) @(posedge dsp_clk);
        @(negedge dsp_clk);
        resetn = 1'b1;
        wait (accepted_iq_samples >= 126_000);
        repeat (100) @(posedge dsp_clk);
        if (!dma_dump_enabled &&
            (dma_words == 0 || rejected_words == 0 || retried_words != rejected_words ||
             retry_expected || !overflow_seen))
            $fatal(1, "DMA retry check failed: words=%0d rejected=%0d retried=%0d pending=%0b overflow_seen=%0b",
                   dma_words, rejected_words, retried_words, retry_expected, overflow_seen);
        if (dma_dump_enabled) begin
            $fclose(dma_dump_fd);
            if (dma_dump_words != dma_words)
                $fatal(1, "DMA dump count=%0d but bridge emitted=%0d", dma_dump_words, dma_words);
            $display("PASS: exported %0d exact little-endian DMA words to %s",
                     dma_dump_words, dma_dump_path);
        end
        if (active1_tag4_count < 8 || active2_tag4_count < 8 ||
            active1_energy / active1_count < 250_000 ||
            active2_energy / active2_count < 250_000)
            $fatal(1, "on-channel FM audio too small: active1=%0d/%0d active2=%0d/%0d",
                   active1_energy, active1_count, active2_energy, active2_count);
        if (quiet_count < 8 || quiet_energy / quiet_count > 40_000)
            $fatal(1, "burst gap did not become quiet: energy=%0d count=%0d",
                   quiet_energy, quiet_count);
        if (active1_pfb_count[4] < 8)
            $fatal(1, "not enough settled channel-4 PFB samples for isolation check: %0d",
                   active1_pfb_count[4]);
        for (integer isolation_ch = 1; isolation_ch <= 7; isolation_ch = isolation_ch + 1) begin
            if (isolation_ch != 4 && active1_pfb_count[isolation_ch] < 8)
                $fatal(1, "not enough settled PFB samples for channel %0d isolation check: %0d",
                       isolation_ch, active1_pfb_count[isolation_ch]);
            if (isolation_ch != 4 &&
                active1_pfb_energy[isolation_ch] * active1_pfb_count[4] * 10_000 >
                active1_pfb_energy[4] * active1_pfb_count[isolation_ch])
                $fatal(1, "channelizer leakage too high: ch4 mean energy=%0d, ch%0d mean energy=%0d",
                       active1_pfb_energy[4] / active1_pfb_count[4], isolation_ch,
                       active1_pfb_energy[isolation_ch] / active1_pfb_count[isolation_ch]);
        end
        $display("PASS: channel-4 FM tags/audio and gap/recovery validated; RMS-squared active=%0d/%0d gap=%0d, other-channel energy=%0d/%0d; %0d DMA stalls retried",
                 active1_energy / active1_count, active2_energy / active2_count,
                 quiet_energy / quiet_count, active1_other_energy,
                 active2_other_energy, retried_words);
        $display("PASS: PFB channel-4 mean IQ energy=%0d; adjacent FRS-bin leakage is below -40 dB power",
                 active1_pfb_energy[4] / active1_pfb_count[4]);
        for (integer pfb_ch = 1; pfb_ch <= 7; pfb_ch = pfb_ch + 1)
            $display("PFB channel %0d mean IQ energy=%0d (%0d samples)", pfb_ch,
                     active1_pfb_energy[pfb_ch] / active1_pfb_count[pfb_ch],
                     active1_pfb_count[pfb_ch]);
        for (integer report_ch = 1; report_ch <= 7; report_ch = report_ch + 1)
            $display("channel %0d RMS-squared=%0d / %0d", report_ch,
                     active1_channel_energy[report_ch] / active1_count,
                     active2_channel_energy[report_ch] / active2_count);
        $finish;
    end
endmodule
