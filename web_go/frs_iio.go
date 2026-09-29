package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// IIOConfig describes the libiio command-line capture path. In FRS mode the
// selected scan bytes must carry the custom FRS DMA ABI, not ordinary AD936x
// IQ samples. Defaults target the intended protocol-specific kernel endpoint;
// selecting cf-ad9361-lpc and voltage0..3 is an explicit legacy shim only.
type IIOConfig struct {
	Binary       string
	URI          string
	BufferSize   int
	Device       string
	ScanElements []string
}

func (c IIOConfig) args() ([]string, error) {
	if strings.TrimSpace(c.URI) == "" {
		return nil, errors.New("IIO URI is required")
	}
	if c.BufferSize < 1 || c.BufferSize > 1<<20 {
		return nil, errors.New("IIO buffer size must be between 1 and 1048576 scan frames")
	}
	device := strings.TrimSpace(c.Device)
	if device == "" {
		device = "frs-audio"
	}
	if strings.ContainsAny(device, " \t\r\n,/;|'\"&$`(){}[]") {
		return nil, fmt.Errorf("invalid IIO device name %q", c.Device)
	}
	elements := c.ScanElements
	if len(elements) == 0 {
		// IIO_GENERIC_DATA channel IDs are generated from channel type and
		// scan index. The stable libiio ID is data0; extend_name supplies
		// the human-readable label, not the channel ID.
		elements = []string{"data0"}
	}
	args := []string{"-u", c.URI, "-b", strconv.Itoa(c.BufferSize), "-s", "0", device}
	for _, element := range elements {
		name := strings.TrimSpace(element)
		if name == "" || strings.ContainsAny(name, " \t\r\n,/;|'\"&$`(){}[]") {
			return nil, fmt.Errorf("invalid IIO scan element name %q", element)
		}
		args = append(args, name)
	}
	return args, nil
}

// RunFRSIIO starts iio_readdev without a shell and pipes its raw stdout through
// the exact same DMA decoder used by capture-file mode. It exits only when the
// parent cancels, the stream is malformed, or iio_readdev exits unexpectedly.
// Cancellation sends SIGINT first (matching the tool's normal Ctrl-C cleanup),
// then kills the process after a bounded grace period.
func RunFRSIIO(ctx context.Context, cfg IIOConfig, h *Hub) error {
	args, err := cfg.args()
	if err != nil {
		return err
	}
	if cfg.Binary == "" {
		cfg.Binary = "iio_readdev"
	}
	childCtx, cancelChild := context.WithCancel(ctx)
	defer cancelChild()
	cmd := exec.CommandContext(childCtx, cfg.Binary, args...)
	cmd.WaitDelay = 2 * time.Second
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return cmd.Process.Signal(os.Interrupt)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("create iio_readdev stdout pipe: %w", err)
	}
	stderr := &tailBuffer{limit: 16 * 1024}
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start iio_readdev: %w", err)
	}
	ingestErr := NewFRSDMAIngestor(h).Ingest(stdout)
	if ingestErr != nil {
		cancelChild()
	}
	waitErr := cmd.Wait()
	if ctx.Err() != nil {
		return nil
	}
	if ingestErr != nil {
		return fmt.Errorf("decode iio_readdev capture: %w (stderr: %s)", ingestErr, strings.TrimSpace(stderr.String()))
	}
	if waitErr != nil {
		return fmt.Errorf("iio_readdev exited: %w (stderr: %s)", waitErr, strings.TrimSpace(stderr.String()))
	}
	return errors.New("iio_readdev ended unexpectedly while continuous capture was requested")
}

type tailBuffer struct {
	limit int
	data  []byte
}

func (b *tailBuffer) Write(p []byte) (int, error) {
	n := len(p)
	if n >= b.limit {
		b.data = append(b.data[:0], p[n-b.limit:]...)
		return n, nil
	}
	if extra := len(b.data) + n - b.limit; extra > 0 {
		copy(b.data, b.data[extra:])
		b.data = b.data[:len(b.data)-extra]
	}
	b.data = append(b.data, p...)
	return n, nil
}

func (b *tailBuffer) String() string { return string(b.data) }

// runFRSIIOUntilSignal is separated for tests and main: it provides graceful
// interrupt/TERM cancellation without introducing platform-specific CGO.
func runFRSIIOUntilSignal(cfg IIOConfig, h *Hub) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return RunFRSIIO(ctx, cfg, h)
}
