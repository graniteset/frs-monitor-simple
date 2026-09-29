package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestIIOConfigDefaultsToProtocolSpecificFRSScan(t *testing.T) {
	cfg := IIOConfig{URI: "ip:192.168.2.1", BufferSize: 256}
	got, err := cfg.args()
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"-u", "ip:192.168.2.1", "-b", "256", "-s", "0", "frs-audio", "data0"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("args=%q want=%q", got, want)
	}
	for _, bad := range []IIOConfig{{BufferSize: 256}, {URI: "ip:test", BufferSize: 0}, {URI: "ip:test", BufferSize: 1 << 21}} {
		if _, err := bad.args(); err == nil {
			t.Errorf("accepted invalid config %#v", bad)
		}
	}

	cfg.Device = "cf-ad9361-lpc"
	cfg.ScanElements = []string{"voltage0", "voltage1", "voltage2", "voltage3"}
	got, err = cfg.args()
	if err != nil {
		t.Fatal(err)
	}
	want = []string{"-u", "ip:192.168.2.1", "-b", "256", "-s", "0", "cf-ad9361-lpc", "voltage0", "voltage1", "voltage2", "voltage3"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("explicit legacy transport-shim args=%q want=%q", got, want)
	}
	for _, bad := range []IIOConfig{
		{URI: "ip:test", BufferSize: 1, Device: "frs-audio;sh"},
		{URI: "ip:test", BufferSize: 1, ScanElements: []string{"data0,voltage0"}},
		{URI: "ip:test", BufferSize: 1, ScanElements: []string{""}},
	} {
		if _, err := bad.args(); err == nil {
			t.Errorf("accepted invalid device/scan config %#v", bad)
		}
	}
}

func TestRunFRSIIOFakeExecutableStreamsWordsAndReportsExit(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("test fake command uses a POSIX shell")
	}
	dir := t.TempDir()
	dataPath := filepath.Join(dir, "capture.bin")
	argsPath := filepath.Join(dir, "args.txt")
	script := filepath.Join(dir, "iio_readdev")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$IIO_TEST_ARGS\"\ncat \"$IIO_TEST_DATA\"\necho deliberate-test-error >&2\nexit 7\n"), 0700); err != nil {
		t.Fatal(err)
	}
	var capture bytes.Buffer
	for n := 0; n < frsDMASamplesPerChunk; n++ {
		for ch := 1; ch <= 22; ch += 2 {
			a, b := int16(0), int16(0)
			if ch == 3 {
				a = 2200
			}
			if ch+1 == 3 {
				b = 2200
			}
			capture.Write(packedTestWord(FRSRecord{Channel: ch, Sample: a}, FRSRecord{Channel: ch + 1, Sample: b}))
		}
	}
	if err := os.WriteFile(dataPath, capture.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("IIO_TEST_DATA", dataPath)
	t.Setenv("IIO_TEST_ARGS", argsPath)
	h := NewHub()
	err := RunFRSIIO(context.Background(), IIOConfig{
		Binary: script, URI: "ip:192.168.2.1", BufferSize: 256,
		Device: "frs-audio", ScanElements: []string{"data0"},
	}, h)
	if err == nil || !strings.Contains(err.Error(), "exit status 7") || !strings.Contains(err.Error(), "deliberate-test-error") {
		t.Fatalf("unexpected process error: %v", err)
	}
	args, err := os.ReadFile(argsPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(args) != "-u\nip:192.168.2.1\n-b\n256\n-s\n0\nfrs-audio\ndata0\n" {
		t.Fatalf("child args=%q", args)
	}
	snap := h.Snapshot()
	if len(snap.Frames) != 1 || len(snap.Records) != 1 || snap.Records[0].Channel != 3 {
		t.Fatalf("stdout not consumed by DMA decoder: frames=%d records=%#v", len(snap.Frames), snap.Records)
	}
}

func TestRunFRSIIOCancellationInterruptsLongRunningReader(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("test fake command uses a POSIX shell")
	}
	dir := t.TempDir()
	dataPath := filepath.Join(dir, "capture.bin")
	script := filepath.Join(dir, "iio_readdev")
	if err := os.WriteFile(script, []byte("#!/bin/sh\ncat \"$IIO_TEST_DATA\"\nexec sleep 30\n"), 0700); err != nil {
		t.Fatal(err)
	}
	var capture bytes.Buffer
	for n := 0; n < frsDMASamplesPerChunk; n++ {
		for ch := 1; ch <= 22; ch += 2 {
			capture.Write(packedTestWord(FRSRecord{Channel: ch, Sample: 0}, FRSRecord{Channel: ch + 1, Sample: 0}))
		}
	}
	if err := os.WriteFile(dataPath, capture.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("IIO_TEST_DATA", dataPath)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	h := NewHub()
	done := make(chan error, 1)
	go func() { done <- RunFRSIIO(ctx, IIOConfig{Binary: script, URI: "ip:test", BufferSize: 256}, h) }()
	deadline := time.Now().Add(3 * time.Second)
	for len(h.Snapshot().Frames) == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if len(h.Snapshot().Frames) == 0 {
		cancel()
		t.Fatal("fake reader did not deliver a complete frame")
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("normal cancellation returned error: %v", err)
		}
	case <-time.After(4 * time.Second):
		t.Fatal("iio_readdev process did not stop on cancellation")
	}
}
