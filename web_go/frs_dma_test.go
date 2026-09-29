package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"math"
	"testing"
)

func packedTestWord(a, b FRSRecord) []byte {
	w := uint64(2) << 62
	w |= uint64(uint16(a.Sample)) | uint64(a.Channel)<<16
	w |= (uint64(uint16(b.Sample)) | uint64(b.Channel)<<16) << 21
	out := make([]byte, 8)
	binary.LittleEndian.PutUint64(out, w)
	return out
}

func TestDecodeFRSDMAWord(t *testing.T) {
	// Fixed cross-language ABI vector, written as bytes rather than produced by
	// packedTestWord so the test can catch a shared encoder/decoder bit-order bug.
	// RTL word: {count=2, reserved=0, rec1={22,32767}, rec0={3,-12345}}.
	golden := []byte{0xc7, 0xcf, 0xe3, 0xff, 0xcf, 0x02, 0x00, 0x80}
	if encoded := packedTestWord(FRSRecord{Channel: 3, Sample: -12345}, FRSRecord{Channel: 22, Sample: 32767}); !bytes.Equal(encoded, golden) {
		t.Fatalf("test encoder bytes=% x want ABI golden=% x", encoded, golden)
	}
	got, err := DecodeFRSDMAWord(golden)
	if err != nil {
		t.Fatal(err)
	}
	if got[0] != (FRSRecord{Channel: 3, Sample: -12345}) || got[1] != (FRSRecord{Channel: 22, Sample: 32767}) {
		t.Fatalf("decoded %#v", got)
	}
	for name, data := range map[string][]byte{
		"short": {1, 2, 3},
		"count": func() []byte {
			b := packedTestWord(FRSRecord{Channel: 1}, FRSRecord{Channel: 2})
			binary.LittleEndian.PutUint64(b, binary.LittleEndian.Uint64(b)&^(uint64(3)<<62))
			return b
		}(),
		"reserved": func() []byte {
			b := packedTestWord(FRSRecord{Channel: 1}, FRSRecord{Channel: 2})
			binary.LittleEndian.PutUint64(b, binary.LittleEndian.Uint64(b)|(1<<42))
			return b
		}(),
		"tag": packedTestWord(FRSRecord{Channel: 0}, FRSRecord{Channel: 2}),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := DecodeFRSDMAWord(data); err == nil {
				t.Fatal("expected malformed word rejection")
			}
		})
	}
}

func TestFRSDMAIngestProducesTaggedAudioActivityAndMix(t *testing.T) {
	h := NewHub()
	var stream bytes.Buffer
	// Interleave all 22 channels at equal per-channel rates. Only channel 3
	// carries a tone; this is independent record-level fixture data, not RTL output.
	for sample := 0; sample < frsDMASamplesPerChunk; sample++ {
		for ch := 1; ch <= 22; ch += 2 {
			a := int16(0)
			if ch == 3 {
				a = 2400
			}
			b := int16(0)
			if ch+1 == 3 {
				b = 2400
			}
			stream.Write(packedTestWord(FRSRecord{Channel: ch, Sample: a}, FRSRecord{Channel: ch + 1, Sample: b}))
		}
	}
	if err := NewFRSDMAIngestor(h).Ingest(&stream); err != nil {
		t.Fatal(err)
	}
	snap := h.Snapshot()
	if len(snap.Frames) != 1 || len(snap.Audio) != 1 || len(snap.Records) != 1 {
		t.Fatalf("frames/audio/records=%d/%d/%d", len(snap.Frames), len(snap.Audio), len(snap.Records))
	}
	if snap.SessionLabel != "FPGA audio activity (not RF spectrum)" {
		t.Fatalf("misleading mode label %q", snap.SessionLabel)
	}
	if snap.CenterHz != defaultCenterHz || snap.SampleRate != frsReceiverSampleRate {
		t.Fatalf("FRS receiver profile center/rate=%d/%d want %d/%d", snap.CenterHz, snap.SampleRate, defaultCenterHz, frsReceiverSampleRate)
	}
	r := snap.Records[0]
	if r.Channel != 3 || r.End == nil {
		t.Fatalf("record %#v", r)
	}
	bin := int(math.Round(float64(r.Frequency-(snap.CenterHz-int64(snap.SampleRate/2))) * float64(defaultFFTBins) / float64(snap.SampleRate)))
	if snap.Frames[0].Row[bin] < 90 {
		t.Fatalf("channel 3 activity marker=%d", snap.Frames[0].Row[bin])
	}
	if len(h.ChannelAudioBetween(3, r.Start, *r.End+0.02)) != 1 || len(h.ChannelAudioBetween(4, r.Start, *r.End+0.02)) != 1 {
		t.Fatal("per-channel audio not retained")
	}
	if got := int16(binary.LittleEndian.Uint16(snap.Audio[0].PCM)); got != 2400 {
		t.Fatalf("mixed first sample=%d", got)
	}
	server, err := NewServer(h, "dma-test")
	if err != nil {
		t.Fatal(err)
	}
	updates := request(t, server.Handler(), "GET", "/api/updates?after=0&since=0&token=dma-test")
	if updates.Code != 200 || !bytes.Contains(updates.Body.Bytes(), []byte(`"channel":3`)) {
		t.Fatalf("dashboard activity response status=%d body=%s", updates.Code, updates.Body.String())
	}
	live := request(t, server.Handler(), "GET", "/api/live?after=0&token=dma-test")
	if live.Code != 200 || !bytes.Contains(live.Body.Bytes(), []byte(`"latest":1`)) {
		t.Fatalf("live audio response status=%d body=%s", live.Code, live.Body.String())
	}
	channelPCM := server.renderPCM(3, r.Start, frsDMASamplesPerChunk, defaultAudioRate, h.ChannelRecords(3), h.ChannelAudioBetween(3, r.Start, r.Start+0.02))
	if got := int16(binary.LittleEndian.Uint16(channelPCM)); got != 2400 {
		t.Fatalf("channel playback sample=%d", got)
	}
}

func TestFRSDMARejectsTruncatedCapture(t *testing.T) {
	h := NewHub()
	err := NewFRSDMAIngestor(h).Ingest(bytes.NewReader([]byte{1, 2, 3}))
	if err == nil || err == io.EOF {
		t.Fatalf("truncated word error=%v", err)
	}
}

func TestFRSDMAPartialFinalFrameEndsAtActualSampleTime(t *testing.T) {
	h := NewHub()
	const samples = frsDMASamplesPerChunk + 37
	var stream bytes.Buffer
	for n := 0; n < samples; n++ {
		for ch := 1; ch <= 22; ch += 2 {
			a, b := int16(0), int16(0)
			if ch == 3 {
				a = 2400
			}
			if ch+1 == 3 {
				b = 2400
			}
			stream.Write(packedTestWord(FRSRecord{Channel: ch, Sample: a}, FRSRecord{Channel: ch + 1, Sample: b}))
		}
	}
	if err := NewFRSDMAIngestor(h).Ingest(&stream); err != nil {
		t.Fatal(err)
	}
	snap := h.Snapshot()
	if len(snap.Frames) != 2 || len(snap.Records) != 1 || snap.Records[0].End == nil {
		t.Fatalf("frames/records=%d/%#v", len(snap.Frames), snap.Records)
	}
	gotDuration := *snap.Records[0].End - snap.Records[0].Start
	wantDuration := float64(samples) / float64(defaultAudioRate)
	if math.Abs(gotDuration-wantDuration) > 1e-6 {
		t.Fatalf("record duration=%0.8f want %0.8f", gotDuration, wantDuration)
	}
}

func TestAudioRMSGateUsesHysteresisAndHold(t *testing.T) {
	var gate audioRMSGate
	if gate.Update(99, 100, 1.00) {
		t.Fatal("opened below selected RMS floor")
	}
	if !gate.Update(100, 100, 1.02) {
		t.Fatal("did not open at floor")
	}
	if !gate.Update(72, 100, 1.04) {
		t.Fatal("closed inside 3 dB hysteresis band")
	}
	if !gate.Update(60, 100, 1.06) {
		t.Fatal("closed before 200 ms hold")
	}
	if !gate.Update(60, 100, 1.24) {
		t.Fatal("closed before hold duration elapsed")
	}
	if gate.Update(60, 100, 1.261) {
		t.Fatal("did not close after 200 ms below close threshold")
	}
	if !gate.Update(120, 100, 1.28) {
		t.Fatal("failed to reopen above floor")
	}
}
