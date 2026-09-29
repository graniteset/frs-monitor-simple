package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestRTLDMAToGoHTTP is an opt-in integration test: it runs the actual RTL
// bridge testbench with deterministic channel-4 FM IQ, ingests the bytes that
// the bridge emitted, and checks the web API/audio stream. Keeping it opt-in
// leaves ordinary Go unit tests independent of Icarus Verilog.
func TestRTLDMAToGoHTTP(t *testing.T) {
	if os.Getenv("FRS_RTL_E2E") != "1" {
		t.Skip("set FRS_RTL_E2E=1 (or run make test-dma-e2e) to invoke Icarus RTL")
	}
	for _, tool := range []string{"iverilog", "vvp"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Fatalf("required RTL simulator %q not found: %v", tool, err)
		}
	}
	repoRoot, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	tmp := t.TempDir()
	simPath := filepath.Join(tmp, "frs_bridge.vvp")
	dmaPath := filepath.Join(tmp, "frs_dma.bin")
	rtl := []string{
		"fpga/iq_test_source.sv", "fpga/frs_fm_test_source.sv", "fpga/axis_iq_mux.sv",
		"fpga/band_ddc_decimator.sv", "fpga/sparse_channelizer.sv", "fpga/axis_rr_merge2_iq.sv",
		"fpga/complex_squelch.sv", "fpga/quadrature_demod.sv", "fpga/fm_deemphasis.sv",
		"fpga/audio_fir_decimator.sv", "fpga/frs_channel_audio.sv", "fpga/frs_multi_channel_audio.sv",
		"fpga/frs_receive_core.sv", "fpga/frs_async_fifo.sv", "fpga/frs_ad9361_rx_adapter.sv",
		"fpga/frs_ad9361_dma_bridge.sv", "fpga/tb_frs_ad9361_dma_bridge.sv",
	}
	compileArgs := []string{"-g2012", "-s", "tb_frs_ad9361_dma_bridge", "-o", simPath}
	compileArgs = append(compileArgs, rtl...)
	compile := exec.Command("iverilog", compileArgs...)
	compile.Dir = repoRoot
	if out, err := compile.CombinedOutput(); err != nil {
		t.Fatalf("compile RTL E2E bench: %v\n%s", err, out)
	} else if len(bytes.TrimSpace(out)) != 0 {
		t.Logf("iverilog: %s", strings.TrimSpace(string(out)))
	}

	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	sim := exec.CommandContext(ctx, "vvp", simPath, "+DMA_DUMP="+dmaPath)
	sim.Dir = repoRoot // coefficient memory paths are intentionally project-relative.
	out, err := sim.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("RTL E2E simulation exceeded 180 seconds\n%s", out)
	}
	if err != nil {
		t.Fatalf("run RTL E2E simulation: %v\n%s", err, out)
	}
	for _, marker := range []string{"PASS: exported ", "PASS: channel-4 FM tags/audio"} {
		if !bytes.Contains(out, []byte(marker)) {
			t.Fatalf("simulation missed %q\n%s", marker, out)
		}
	}
	info, err := os.Stat(dmaPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() == 0 || info.Size()%8 != 0 {
		t.Fatalf("RTL DMA capture has invalid size %d (must be nonzero and 8-byte aligned)", info.Size())
	}
	t.Logf("RTL emitted %d exact 64-bit words (%d bytes)", info.Size()/8, info.Size())

	hub := NewHub()
	capture, err := os.Open(dmaPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := NewFRSDMAIngestor(hub).Ingest(capture); err != nil {
		_ = capture.Close()
		t.Fatalf("ingest RTL DMA bytes: %v", err)
	}
	if err := capture.Close(); err != nil {
		t.Fatal(err)
	}
	hub.archived = true // make the HTTP channel stream return one bounded timeline segment.
	snap := hub.Snapshot()
	if len(snap.Frames) == 0 || len(snap.Records) == 0 {
		t.Fatalf("RTL DMA produced no dashboard data: frames=%d records=%d", len(snap.Frames), len(snap.Records))
	}
	var channel4 *Record
	for n := range snap.Records {
		if snap.Records[n].Channel == 4 {
			channel4 = &snap.Records[n]
			break
		}
	}
	if channel4 == nil || channel4.End == nil {
		t.Fatalf("RTL DMA produced no completed channel-4 activity record: %#v", snap.Records)
	}
	if len(hub.ChannelAudioBetween(4, channel4.Start, *channel4.End+0.01)) == 0 {
		t.Fatal("channel-4 activity has no retained per-channel audio")
	}

	server, err := NewServer(hub, "rtl-e2e")
	if err != nil {
		t.Fatal(err)
	}
	h := server.Handler()
	updates := request(t, h, http.MethodGet, "/api/updates?after=0&since=0&token=rtl-e2e")
	if updates.Code != http.StatusOK {
		t.Fatalf("updates status=%d body=%s", updates.Code, updates.Body.String())
	}
	var payload struct {
		Frames  [][]any          `json:"frames"`
		Records []map[string]any `json:"records"`
	}
	if err := json.Unmarshal(updates.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	foundActivity := false
	for _, record := range payload.Records {
		if record["channel"] == float64(4) {
			foundActivity = true
		}
	}
	if !foundActivity || len(payload.Frames) == 0 {
		t.Fatalf("dashboard updates missing channel-4 activity/frames: %s", updates.Body.String())
	}

	live := request(t, h, http.MethodGet, "/api/live?after=0&token=rtl-e2e")
	if live.Code != http.StatusOK || !bytes.Contains(live.Body.Bytes(), []byte(`"latest":1`)) {
		t.Fatalf("live endpoint status=%d body=%s", live.Code, live.Body.String())
	}

	streamPath := fmt.Sprintf("/api/channel-stream?channel=4&start=%.9f&token=rtl-e2e", channel4.Start)
	stream := request(t, h, http.MethodGet, streamPath)
	if stream.Code != http.StatusOK || stream.Header().Get("Content-Type") != "application/octet-stream" {
		t.Fatalf("channel stream status=%d type=%q", stream.Code, stream.Header().Get("Content-Type"))
	}
	if len(stream.Body.Bytes()) != defaultAudioRate/10*2 {
		t.Fatalf("channel stream bytes=%d want one 100ms segment (%d)", len(stream.Body.Bytes()), defaultAudioRate/10*2)
	}
	nonzero := false
	for i := 0; i+1 < len(stream.Body.Bytes()); i += 2 {
		if int16(binary.LittleEndian.Uint16(stream.Body.Bytes()[i:i+2])) != 0 {
			nonzero = true
			break
		}
	}
	if !nonzero {
		t.Fatalf("channel-4 HTTP audio stream contains no nonzero PCM sample")
	}
	t.Logf("HTTP updates/live/channel-stream passed; channel-4 record duration %.3f ms", (*channel4.End-channel4.Start)*1000)
}
