package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	listen := flag.String("listen", "0.0.0.0:8765", "HTTP listen address")
	token := flag.String("token", "", "dashboard access token (random if omitted)")
	sourceKind := flag.String("source", "synthetic", "input source: synthetic or fixture")
	fixture := flag.String("fixture", "", "fixture JSON file (required for -source fixture)")
	replay := flag.Bool("fixture-replay", false, "replay seeded fixture PCM repeatedly for live-stream testing")
	flag.Parse()

	var store *Hub
	var err error
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
	default:
		log.Fatalf("unknown source %q", *sourceKind)
	}
	defer store.Close()

	server, err := NewServer(store, *token)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("LISTENING http://%s/?token=%s", *listen, server.token)
	if err := http.ListenAndServe(*listen, server.Handler()); err != nil && err != http.ErrServerClosed {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
