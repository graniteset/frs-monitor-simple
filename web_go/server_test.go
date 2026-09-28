package main

import (
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testServer(t *testing.T) (*Hub, *Server) {
	t.Helper()
	h := NewHub()
	h.archived = true
	h.started = time.Unix(100, 0)
	if err := h.AddFrame(Frame{Seq: 1, Time: 100, Row: make([]byte, defaultFFTBins)}); err != nil {
		t.Fatal(err)
	}
	if err := h.AddFrame(Frame{Seq: 2, Time: 100.05, Row: bytesRepeat(7, defaultFFTBins)}); err != nil {
		t.Fatal(err)
	}
	end := 100.04
	if err := h.AddRecord(Record{ID: 9, Channel: 3, Frequency: 462612500, Start: 100.01, End: &end, Path: "sample.wav"}); err != nil {
		t.Fatal(err)
	}
	if err := h.AddAudio(Chunk{Seq: 1, PCM: []byte{1, 0, 2, 0}}); err != nil {
		t.Fatal(err)
	}
	s, err := NewServer(h, "test-token")
	if err != nil {
		t.Fatal(err)
	}
	return h, s
}

func bytesRepeat(v byte, n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = v
	}
	return b
}

func readWAVBytes(b []byte) ([]byte, int, error) {
	if len(b) < 44 || string(b[:4]) != "RIFF" || string(b[8:12]) != "WAVE" {
		return nil, 0, os.ErrInvalid
	}
	return b[44:], int(binary.LittleEndian.Uint32(b[24:28])), nil
}

func request(t *testing.T, handler http.Handler, method, path string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, path, nil)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	return w
}

func TestDashboardEmbeddedCopyMatchesExistingUI(t *testing.T) {
	source, err := os.ReadFile(filepath.Join("..", "web", "dashboard.html"))
	if err != nil {
		t.Fatal(err)
	}
	if string(source) != dashboardHTML {
		t.Fatal("embedded dashboard copy diverges from web/dashboard.html")
	}
}

func TestTokenProtectionAndDashboardSubstitution(t *testing.T) {
	_, s := testServer(t)
	h := s.Handler()
	if got := request(t, h, http.MethodGet, "/").Code; got != http.StatusForbidden {
		t.Fatalf("missing-token status=%d", got)
	}
	w := request(t, h, http.MethodGet, "/?token=test-token")
	if w.Code != 200 {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	for _, want := range []string{"const TOKEN='test-token'", "CENTER=465125000", "RATE=8000000", "AUDIO_RATE=12500", "ARCHIVED=true", "width=device-width"} {
		if !strings.Contains(w.Body.String(), want) {
			t.Errorf("page missing %q", want)
		}
	}
	if got := request(t, h, http.MethodGet, "/api/does-not-exist?token=test-token").Code; got != http.StatusNotFound {
		t.Fatalf("unknown path status=%d; want 404", got)
	}
}

func TestUpdatesHistoryAndLiveJSONShapes(t *testing.T) {
	_, s := testServer(t)
	h := s.Handler()
	w := request(t, h, "GET", "/api/updates?after=0&since=0"+"&token=test-token")
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	var updates struct {
		Frames   [][]any          `json:"frames"`
		Records  []map[string]any `json:"records"`
		Timeline Timeline         `json:"timeline"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &updates); err != nil {
		t.Fatal(err)
	}
	if len(updates.Frames) != 2 || len(updates.Records) != 1 || updates.Timeline.Live {
		t.Fatalf("unexpected updates %#v", updates)
	}
	encoded, ok := updates.Frames[0][2].(string)
	if !ok {
		t.Fatalf("frame payload type %T", updates.Frames[0][2])
	}
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(decoded) != 4096 {
		t.Fatalf("frame encoding length=%d err=%v", len(decoded), err)
	}
	if _, ok := updates.Records[0]["path"]; ok {
		t.Fatal("public record must not disclose storage path")
	}
	w = request(t, h, "GET", "/api/history?before=100.051&limit=1&token=test-token")
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	var history map[string]json.RawMessage
	if err := json.Unmarshal(w.Body.Bytes(), &history); err != nil {
		t.Fatal(err)
	}
	if _, ok := history["more_before"]; !ok {
		t.Fatal("history response missing more_before")
	}
	w = request(t, h, "GET", "/api/live?after=0&token=test-token")
	var live struct {
		Chunks [][]any `json:"chunks"`
		Latest int64   `json:"latest"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &live); err != nil {
		t.Fatal(err)
	}
	if w.Code != 200 || live.Latest != 1 || len(live.Chunks) != 1 {
		t.Fatalf("live response=%s", w.Body.String())
	}
}

func TestInputValidationAndSquelch(t *testing.T) {
	hub, s := testServer(t)
	h := s.Handler()
	for _, path := range []string{"/api/updates?after=-1&token=test-token", "/api/history?before=NaN&token=test-token", "/api/history?before=100&limit=1601&token=test-token", "/api/live?after=-1&token=test-token", "/api/channel-stream?channel=23&start=1&token=test-token", "/api/recording?id=-1&token=test-token"} {
		if got := request(t, h, "GET", path).Code; got != 400 {
			t.Errorf("%s status=%d", path, got)
		}
	}
	if got := request(t, h, "POST", "/api/squelch?value=-40&token=test-token").Code; got != 409 {
		t.Fatalf("archived squelch status=%d", got)
	}
	hub.archived = false
	if got := request(t, h, "POST", "/api/squelch?value=-40&token=test-token").Code; got != 204 || hub.Squelch() != -40 {
		t.Fatalf("squelch status=%d level=%v", got, hub.Squelch())
	}
	if got := request(t, h, "POST", "/api/squelch?value=1&token=test-token").Code; got != 400 {
		t.Fatalf("invalid squelch status=%d", got)
	}
}

func TestFixtureLoading(t *testing.T) {
	fixture := `{"center_hz":100,"sample_rate":200,"audio_rate":12500,"archived":true,"frames":[{"seq":1,"time":10,"row":"` + base64.StdEncoding.EncodeToString(make([]byte, defaultFFTBins)) + `"}],"records":[],"audio":[{"seq":1,"pcm":"AQACAA=="}],"squelch":-63}`
	path := filepath.Join(t.TempDir(), "fixture.json")
	if err := os.WriteFile(path, []byte(fixture), 0600); err != nil {
		t.Fatal(err)
	}
	h, err := LoadFixture(path)
	if err != nil {
		t.Fatal(err)
	}
	snap := h.Snapshot()
	if snap.CenterHz != 100 || snap.SampleRate != 200 || !snap.Archived || h.Squelch() != -63 || len(snap.Frames) != 1 || len(snap.Audio) != 1 {
		t.Fatalf("loaded snapshot %#v", snap)
	}
}

func TestWAVOffsetRendering(t *testing.T) {
	pcm := []byte{1, 0, 2, 0, 3, 0, 4, 0}
	wav := wavBytes(pcm, 12500)
	path := filepath.Join(t.TempDir(), "a.wav")
	if err := os.WriteFile(path, wav, 0600); err != nil {
		t.Fatal(err)
	}
	data, rate, err := readWAV(path)
	if err != nil || rate != 12500 || string(data) != string(pcm) {
		t.Fatalf("read wav rate=%d data=%v err=%v", rate, data, err)
	}
	h, s := testServer(t)
	end := 100.04
	h.mu.Lock()
	h.records[0].Path = path
	h.mu.Unlock()
	w := request(t, s.Handler(), "GET", "/api/recording?id=9&offset=0.00008&token=test-token")
	if w.Code != 200 || w.Header().Get("Content-Type") != "audio/wav" {
		t.Fatalf("recording response status=%d type=%q", w.Code, w.Header().Get("Content-Type"))
	}
	trimmed, trimmedRate, err := readWAVBytes(w.Body.Bytes())
	if err != nil || trimmedRate != 12500 || string(trimmed) != string(pcm[2:]) {
		t.Fatalf("recording offset output rate=%d bytes=%v err=%v", trimmedRate, trimmed, err)
	}
	h2 := NewHub()
	if err := h2.AddRecord(Record{ID: 10, Channel: 3, Frequency: 462612500, Start: 100, End: &end, Path: path}); err != nil {
		t.Fatal(err)
	}
	rendered := s.renderPCM(3, 100, 4, h2.Snapshot().AudioRate, h2.ChannelRecords(3))
	if string(rendered) != string(pcm) {
		t.Fatalf("channel render=%v want=%v", rendered, pcm)
	}
}
