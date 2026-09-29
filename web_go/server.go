package main

import (
	"bytes"
	"crypto/rand"
	_ "embed"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

//go:embed static/dashboard.html
var dashboardHTML string

type Server struct {
	source *Hub
	token  string
}

func NewServer(source *Hub, token string) (*Server, error) {
	if source == nil {
		return nil, errors.New("source is required")
	}
	if token == "" {
		b := make([]byte, 24)
		if _, err := rand.Read(b); err != nil {
			return nil, err
		}
		token = base64.RawURLEncoding.EncodeToString(b)
	} else if len(token) > 128 || strings.Trim(token, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != "" {
		return nil, errors.New("token must contain only URL-safe characters")
	}
	return &Server{source: source, token: token}, nil
}
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.root)
	mux.HandleFunc("/api/updates", s.updates)
	mux.HandleFunc("/api/history", s.history)
	mux.HandleFunc("/api/live", s.live)
	mux.HandleFunc("/api/live-stream", s.liveStream)
	mux.HandleFunc("/api/channel-stream", s.channelStream)
	mux.HandleFunc("/api/recording", s.recording)
	mux.HandleFunc("/api/squelch", s.squelch)
	return securityHeaders(mux)
}
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		next.ServeHTTP(w, r)
	})
}
func (s *Server) authorized(w http.ResponseWriter, r *http.Request) bool {
	if r.URL.Query().Get("token") != s.token {
		writeBytes(w, http.StatusForbidden, "text/plain", []byte("Invalid dashboard token"))
		return false
	}
	return true
}
func (s *Server) root(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !s.authorized(w, r) {
		return
	}
	if r.URL.Path != "/" {
		writeBytes(w, http.StatusNotFound, "text/plain", []byte("Not found"))
		return
	}
	snap := s.source.Summary()
	label, _ := json.Marshal(snap.SessionLabel)
	body := strings.NewReplacer("__TOKEN__", s.token, "__CENTER__", strconv.FormatInt(snap.CenterHz, 10), "__RATE__", strconv.Itoa(snap.SampleRate), "__AUDIO_RATE__", strconv.Itoa(snap.AudioRate), "__ARCHIVED__", strconv.FormatBool(snap.Archived), "__SESSION_LABEL__", string(label)).Replace(dashboardHTML)
	writeBytes(w, http.StatusOK, "text/html; charset=utf-8", []byte(body))
}
func (s *Server) updates(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !s.authorized(w, r) {
		return
	}
	q := r.URL.Query()
	after, e1 := parseInt(q, "after", 0)
	since, e2 := parseFloat(q, "since", 0)
	if e1 != nil || e2 != nil || after < 0 {
		writeBytes(w, 400, "text/plain", []byte("Invalid history cursor"))
		return
	}
	framesData, recordsData, timeline := s.source.Updates(after, since)
	frames := make([][]any, 0, len(framesData))
	records := make([]map[string]any, 0, len(recordsData))
	for _, f := range framesData {
		frames = append(frames, []any{f.Seq, f.Time, base64.StdEncoding.EncodeToString(f.Row)})
	}
	for _, rec := range recordsData {
		records = append(records, publicRecord(rec))
	}
	writeJSON(w, 200, map[string]any{"frames": frames, "records": records, "timeline": timeline})
}
func (s *Server) history(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !s.authorized(w, r) {
		return
	}
	q := r.URL.Query()
	before, e1 := parseFloatRequired(q, "before")
	limit, e2 := parseInt(q, "limit", 900)
	if e1 != nil || e2 != nil || limit < 1 || limit > 1600 {
		writeBytes(w, 400, "text/plain", []byte("Invalid history window"))
		return
	}
	selected, recordsData, more, timeline := s.source.History(before, int(limit))
	frames := make([][]any, 0, len(selected))
	records := make([]map[string]any, 0, len(recordsData))
	for _, f := range selected {
		frames = append(frames, []any{f.Seq, f.Time, base64.StdEncoding.EncodeToString(f.Row)})
	}
	for _, rec := range recordsData {
		records = append(records, publicRecord(rec))
	}
	writeJSON(w, 200, map[string]any{"frames": frames, "records": records, "more_before": more, "timeline": timeline})
}
func (s *Server) live(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !s.authorized(w, r) {
		return
	}
	after, err := parseInt(r.URL.Query(), "after", 0)
	if err != nil || after < 0 {
		writeBytes(w, 400, "text/plain", []byte("Invalid audio cursor"))
		return
	}
	data, latest := s.source.LiveAfter(after)
	chunks := make([][]any, 0, len(data))
	for _, c := range data {
		chunks = append(chunks, []any{c.Seq, base64.StdEncoding.EncodeToString(c.PCM)})
	}
	writeJSON(w, 200, map[string]any{"chunks": chunks, "latest": latest})
}
func (s *Server) liveStream(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !s.authorized(w, r) {
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Connection", "close")
	audioRate := s.source.Summary().AudioRate
	w.Header().Set("X-Audio-Chunk-Bytes", strconv.Itoa(audioRate/50*2))
	w.WriteHeader(200)
	flusher, _ := w.(http.Flusher)
	seq := int64(0)
	if _, latest := s.source.LiveAfter(0); latest > 0 {
		seq = latest
	}
	pending := make([][]byte, 0, 5)
	for {
		if r.Context().Err() != nil {
			return
		}
		for _, c := range s.source.AudioAfter(seq) {
			seq = c.Seq
			pending = append(pending, c.PCM)
		}
		for len(pending) >= 5 {
			for _, pcm := range pending[:5] {
				if _, err := w.Write(pcm); err != nil {
					return
				}
			}
			pending = pending[5:]
			if flusher != nil {
				flusher.Flush()
			}
		}
		select {
		case <-r.Context().Done():
			return
		case <-s.source.closeCh:
			return
		case <-time.After(50 * time.Millisecond):
		}
	}
}
func (s *Server) channelStream(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !s.authorized(w, r) {
		return
	}
	q := r.URL.Query()
	channel, e1 := parseInt(q, "channel", 0)
	start, e2 := parseFloatRequired(q, "start")
	if e1 != nil || e2 != nil || channel < 1 || channel > 22 {
		writeBytes(w, 400, "text/plain", []byte("Invalid channel timeline"))
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Connection", "close")
	audioRate := s.source.Summary().AudioRate
	w.Header().Set("X-Audio-Chunk-Bytes", strconv.Itoa(audioRate/10*2))
	w.WriteHeader(200)
	flusher, _ := w.(http.Flusher)
	origin := time.Now()
	segment := 0
	for {
		snap := s.source.Summary()
		timeline := start + float64(segment)*.1
		if snap.Archived && timeline > snap.Timeline.End {
			return
		}
		pcm := s.renderPCM(int(channel), timeline, snap.AudioRate/10, snap.AudioRate, s.source.ChannelRecords(int(channel)), s.source.ChannelAudioBetween(int(channel), timeline, timeline+0.1))
		if _, err := w.Write(pcm); err != nil {
			return
		}
		if flusher != nil {
			flusher.Flush()
		}
		segment++
		delay := origin.Add(time.Duration(segment) * 100 * time.Millisecond).Sub(time.Now())
		if delay > 0 {
			timer := time.NewTimer(delay)
			select {
			case <-r.Context().Done():
				timer.Stop()
				return
			case <-s.source.closeCh:
				timer.Stop()
				return
			case <-timer.C:
			}
		}
	}
}
func (s *Server) recording(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !s.authorized(w, r) {
		return
	}
	q := r.URL.Query()
	id, e1 := parseInt(q, "id", -1)
	offset, e2 := parseFloat(q, "offset", 0)
	if e1 != nil || e2 != nil || id < 0 || offset < 0 {
		writeBytes(w, 400, "text/plain", []byte("Invalid recording request"))
		return
	}
	rec, found := s.source.FindRecord(id)
	if !found || rec.Path == "" {
		writeBytes(w, 404, "text/plain", []byte("Recording unavailable"))
		return
	}
	if rec.End == nil {
		writeBytes(w, 409, "text/plain", []byte("Recording still active"))
		return
	}
	b, rate, err := readWAV(rec.Path)
	if err != nil {
		writeBytes(w, 404, "text/plain", []byte("Recording unavailable"))
		return
	}
	index := int(math.RoundToEven(offset*float64(rate))) * 2
	if index > len(b) {
		index = len(b)
	}
	writeBytes(w, 200, "audio/wav", wavBytes(b[index:], rate))
}
func (s *Server) squelch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	if !s.authorized(w, r) {
		return
	}
	value, err := parseFloatRequired(r.URL.Query(), "value")
	if err != nil || value < -120 || value > 0 {
		writeBytes(w, 400, "text/plain", []byte("Invalid squelch threshold"))
		return
	}
	if s.source.Summary().Archived {
		writeBytes(w, 409, "text/plain", []byte("Saved session is read-only"))
		return
	}
	if err := s.source.SetSquelch(value); err != nil {
		writeBytes(w, 400, "text/plain", []byte("Invalid squelch threshold"))
		return
	}
	writeBytes(w, 204, "text/plain", nil)
}

func (s *Server) renderPCM(channel int, start float64, n, rate int, records []Record, captured ...[]ChannelChunk) []byte {
	out := make([]byte, n*2)
	if rate < 8000 || rate > 48000 {
		return out
	}
	end := start + float64(n)/float64(rate)
	for _, r := range records {
		rend := end
		if r.End != nil {
			rend = *r.End
		}
		a := math.Max(start, r.Start)
		b := math.Min(end, rend)
		if r.Channel != channel || b <= a || r.Path == "" {
			continue
		}
		data, sourceRate, err := readWAV(r.Path)
		if err != nil {
			continue
		}
		first := max(0, int(math.RoundToEven((a-start)*float64(rate))))
		last := min(n, int(math.RoundToEven((b-start)*float64(rate))))
		if last <= first {
			continue
		}
		for dst := first; dst < last; dst++ {
			srcPos := (start + float64(dst)/float64(rate) - r.Start) * float64(sourceRate)
			lo := int(math.Floor(srcPos))
			hi := lo + 1
			if lo < 0 {
				lo = 0
			}
			if hi*2 >= len(data) {
				hi = lo
			}
			if lo*2 >= len(data) {
				continue
			}
			v0 := float64(int16(binary.LittleEndian.Uint16(data[lo*2:])))
			v1 := float64(int16(binary.LittleEndian.Uint16(data[hi*2:])))
			v := int16(math.RoundToEven(v0 + (v1-v0)*(srcPos-float64(lo))))
			binary.LittleEndian.PutUint16(out[dst*2:], uint16(v))
		}
	}
	// Live FPGA DMA audio is retained in timestamped channel chunks instead of
	// WAV files. Overlay it on any archived recordings for the requested window.
	for _, group := range captured {
		for _, c := range group {
			first := max(0, int(math.Floor((c.Start-start)*float64(rate))))
			last := min(n, int(math.Ceil((c.Start+float64(len(c.PCM)/2)/float64(rate)-start)*float64(rate))))
			for dst := first; dst < last; dst++ {
				src := int(math.RoundToEven((start + float64(dst)/float64(rate) - c.Start) * float64(rate)))
				if src < 0 || src*2+1 >= len(c.PCM) {
					continue
				}
				v := int16(binary.LittleEndian.Uint16(c.PCM[src*2:]))
				binary.LittleEndian.PutUint16(out[dst*2:], uint16(v))
			}
		}
	}
	return out
}

func publicRecord(r Record) map[string]any {
	return map[string]any{"id": r.ID, "channel": r.Channel, "frequency": r.Frequency, "start": r.Start, "end": r.End}
}
func writeBytes(w http.ResponseWriter, status int, content string, b []byte) {
	w.Header().Set("Content-Type", content)
	w.Header().Set("Content-Length", strconv.Itoa(len(b)))
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if len(b) > 0 {
		_, _ = w.Write(b)
	}
}
func writeJSON(w http.ResponseWriter, status int, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		writeBytes(w, 500, "text/plain", []byte("JSON encoding error"))
		return
	}
	writeBytes(w, status, "application/json", b)
}
func methodNotAllowed(w http.ResponseWriter) {
	writeBytes(w, 405, "text/plain", []byte("Method not allowed"))
}
func parseInt(q url.Values, key string, def int64) (int64, error) {
	v := q.Get(key)
	if v == "" {
		return def, nil
	}
	return strconv.ParseInt(v, 10, 64)
}
func parseFloat(q url.Values, key string, def float64) (float64, error) {
	v := q.Get(key)
	if v == "" {
		return def, nil
	}
	f, e := strconv.ParseFloat(v, 64)
	if !finite(f) {
		return 0, errors.New("non-finite number")
	}
	return f, e
}
func parseFloatRequired(q url.Values, key string) (float64, error) {
	v := q.Get(key)
	if v == "" {
		return 0, errors.New("missing value")
	}
	return parseFloat(q, key, 0)
}

// readWAV supports the mono 16-bit PCM wave files written by the Python app.
func readWAV(path string) ([]byte, int, error) {
	b, e := osReadFile(path)
	if e != nil {
		return nil, 0, e
	}
	if len(b) < 44 || string(b[:4]) != "RIFF" || string(b[8:12]) != "WAVE" {
		return nil, 0, errors.New("invalid wav")
	}
	rate, channels, bits, pcmFormat := 0, 0, 0, uint16(0)
	for p := 12; p+8 <= len(b); {
		n := int(binary.LittleEndian.Uint32(b[p+4 : p+8]))
		if n < 0 || p+8+n > len(b) {
			return nil, 0, errors.New("bad wav chunk")
		}
		switch string(b[p : p+4]) {
		case "fmt ":
			if n < 16 {
				return nil, 0, errors.New("short WAV fmt chunk")
			}
			pcmFormat = binary.LittleEndian.Uint16(b[p+8 : p+10])
			channels = int(binary.LittleEndian.Uint16(b[p+10 : p+12]))
			rate = int(binary.LittleEndian.Uint32(b[p+12 : p+16]))
			bits = int(binary.LittleEndian.Uint16(b[p+22 : p+24]))
		case "data":
			if pcmFormat != 1 || channels != 1 || bits != 16 || rate < 8000 || rate > 48000 {
				return nil, 0, errors.New("unsupported WAV format")
			}
			return b[p+8 : p+8+n], rate, nil
		}
		p += 8 + n + (n & 1)
	}
	return nil, 0, errors.New("missing data chunk")
}
func wavBytes(pcm []byte, rate int) []byte {
	var b bytes.Buffer
	b.WriteString("RIFF")
	binary.Write(&b, binary.LittleEndian, uint32(36+len(pcm)))
	b.WriteString("WAVEfmt ")
	binary.Write(&b, binary.LittleEndian, uint32(16))
	binary.Write(&b, binary.LittleEndian, uint16(1))
	binary.Write(&b, binary.LittleEndian, uint16(1))
	binary.Write(&b, binary.LittleEndian, uint32(rate))
	binary.Write(&b, binary.LittleEndian, uint32(rate*2))
	binary.Write(&b, binary.LittleEndian, uint16(2))
	binary.Write(&b, binary.LittleEndian, uint16(16))
	b.WriteString("data")
	binary.Write(&b, binary.LittleEndian, uint32(len(pcm)))
	b.Write(pcm)
	return b.Bytes()
}

// osReadFile is a seam for tests without changing the production WAV path.
var osReadFile = os.ReadFile
