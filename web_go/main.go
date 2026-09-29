package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func main() {
	listen := flag.String("listen", "0.0.0.0:8765", "HTTP listen address")
	token := flag.String("token", "", "dashboard access token (random if omitted)")
	sourceKind := flag.String("source", "synthetic", "input source: synthetic, fixture, frs-dma, or frs-iio")
	fixture := flag.String("fixture", "", "fixture JSON file (required for -source fixture)")
	dmaFile := flag.String("dma-file", "", "FRS DMA capture file or FIFO (required for -source frs-dma; '-' reads stdin)")
	iioURI := flag.String("iio-uri", "", "libiio URI for -source frs-iio, e.g. ip:192.168.2.1 or usb:1.10.5")
	iioReaddev := flag.String("iio-readdev", "iio_readdev", "path to iio_readdev executable")
	iioBuffer := flag.Int("iio-buffer", 256, "IIO scan frames per buffer (default 256)")
	iioDevice := flag.String("iio-device", "frs-audio", "IIO device for -source frs-iio; must expose custom FRS payload (default frs-audio)")
	iioElements := flag.String("iio-elements", "data0", "comma-separated scan elements forming FRS payload bytes (default data0, the generic-data channel ID)")
	replay := flag.Bool("fixture-replay", false, "replay seeded fixture PCM repeatedly for live-stream testing")
	flag.Parse()

	var store *Hub
	var err error
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	var captureDone chan error
	switch *sourceKind {
	case "synthetic":
		store = NewHub()
		store.StartSynthetic()
	case "fixture":
		if *fixture == "" {
			log.Fatal("-fixture is required with -source fixture")
		}
		store, err = LoadFixture(*fixture)
		if err != nil {
			log.Fatal(err)
		}
		if *replay {
			store.StartFixtureReplay()
		}
	case "frs-dma":
		if *dmaFile == "" {
			log.Fatal("-dma-file is required for -source frs-dma")
		}
		store = NewHub()
		var input io.ReadCloser
		if *dmaFile == "-" {
			input = os.Stdin
		} else {
			input, err = os.Open(*dmaFile)
			if err != nil {
				log.Fatal(err)
			}
			defer input.Close()
		}
		go func() {
			if err := NewFRSDMAIngestor(store).Ingest(input); err != nil {
				log.Printf("FRS DMA input stopped: %v", err)
			}
		}()
	case "frs-iio":
		store = NewHub()
		cfg := IIOConfig{Binary: *iioReaddev, URI: *iioURI, BufferSize: *iioBuffer,
			Device: *iioDevice, ScanElements: strings.Split(*iioElements, ",")}
		if _, err := cfg.args(); err != nil {
			log.Fatal(err)
		}
		captureDone = make(chan error, 1)
		go func() {
			captureDone <- RunFRSIIO(runCtx, cfg, store)
			close(captureDone)
		}()
	default:
		log.Fatalf("unknown source %q", *sourceKind)
	}
	defer store.Close()

	server, err := NewServer(store, *token)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("LISTENING http://%s/?token=%s", *listen, server.token)
	httpServer := &http.Server{Addr: *listen, Handler: server.Handler(), ReadHeaderTimeout: 5 * time.Second}
	serveDone := make(chan error, 1)
	go func() { serveDone <- httpServer.ListenAndServe() }()
	select {
	case <-ctx.Done():
		cancel()
	case err := <-captureDone:
		if err != nil {
			log.Printf("FRS IIO capture stopped: %v", err)
		}
		cancel()
	case err := <-serveDone:
		if err != nil && err != http.ErrServerClosed {
			fmt.Fprintln(os.Stderr, err)
			cancel()
		}
	}
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		log.Printf("web shutdown: %v", err)
	}
	if captureDone != nil {
		select {
		case <-captureDone:
		case <-time.After(3 * time.Second):
			log.Printf("timed out waiting for IIO capture shutdown")
		}
	}
}
