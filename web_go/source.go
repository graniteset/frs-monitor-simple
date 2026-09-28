package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"sort"
	"sync"
	"time"
)

const (
	defaultAudioRate  = 12500
	defaultSampleRate = 8000000
	defaultCenterHz   = 465125000
	defaultFFTBins    = 4096
	maxFrames         = 12000
	maxAudioChunks    = 400
	maxHistoryRows    = 1600
)

// Source is the seam between the HTTP/dashboard layer and any future receiver.
// Hardware DMA is intentionally not implemented until its ABI is known.
type Source interface {
	Summary() Snapshot
	Updates(after int64, since float64) ([]Frame, []Record, Timeline)
	History(before float64, limit int) ([]Frame, []Record, bool, Timeline)
	LiveAfter(after int64) ([]Chunk, int64)
	AudioAfter(after int64) []Chunk
	ChannelRecords(channel int) []Record
	FindRecord(id int64) (Record, bool)
	SetSquelch(float64) error
	Squelch() float64
}

type Frame struct {
	Seq  int64   `json:"seq"`
	Time float64 `json:"time"`
	Row  []byte  `json:"row"`
}

type Chunk struct {
	Seq int64  `json:"seq"`
	PCM []byte `json:"pcm"`
}

type Record struct {
	ID        int64    `json:"id"`
	Channel   int      `json:"channel"`
	Frequency int64    `json:"frequency"`
	Start     float64  `json:"start"`
	End       *float64 `json:"end"`
	Path      string   `json:"path,omitempty"`
}

type Timeline struct {
	Start        float64 `json:"start"`
	End          float64 `json:"end"`
	Live         bool    `json:"live"`
	CanLiveAudio bool    `json:"can_live_audio"`
}

type Snapshot struct {
	CenterHz     int64
	SampleRate   int
	AudioRate    int
	Archived     bool
	SessionLabel string
	Frames       []Frame
	Records      []Record
	Audio        []Chunk
	Timeline     Timeline
}

type Fixture struct {
	CenterHz     int64    `json:"center_hz"`
	SampleRate   int      `json:"sample_rate"`
	AudioRate    int      `json:"audio_rate"`
	Archived     bool     `json:"archived"`
	SessionLabel string   `json:"session_label"`
	Frames       []Frame  `json:"frames"`
	Records      []Record `json:"records"`
	Audio        []Chunk  `json:"audio"`
	Squelch      float64  `json:"squelch"`
}

// Hub is an in-memory, bounded timeline and a deterministic fixture target.
// Production source adapters may publish through the same Add* methods.
type Hub struct {
	mu                    sync.RWMutex
	cond                  *sync.Cond
	centerHz              int64
	sampleRate, audioRate int
	archived              bool
	sessionLabel          string
	frames                []Frame
	records               []Record
	audio                 []Chunk
	squelch               float64
	closed                bool
	started               time.Time
	closeCh               chan struct{}
}

func NewHub() *Hub {
	h := &Hub{centerHz: defaultCenterHz, sampleRate: defaultSampleRate, audioRate: defaultAudioRate,
		squelch: -55, started: time.Now(), closeCh: make(chan struct{})}
	h.cond = sync.NewCond(&h.mu)
	return h
}

func LoadFixture(path string) (*Hub, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var f Fixture
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("decode fixture: %w", err)
	}
	h := NewHub()
	h.archived = f.Archived
	h.sessionLabel = f.SessionLabel
	if f.CenterHz != 0 {
		h.centerHz = f.CenterHz
	}
	if f.SampleRate != 0 {
		h.sampleRate = f.SampleRate
	}
	if f.AudioRate != 0 {
		h.audioRate = f.AudioRate
	}
	if f.Squelch != 0 {
		h.squelch = f.Squelch
	}
	for _, row := range f.Frames {
		if err := h.AddFrame(row); err != nil {
			return nil, err
		}
	}
	for _, rec := range f.Records {
		if err := h.AddRecord(rec); err != nil {
			return nil, err
		}
	}
	for _, chunk := range f.Audio {
		if err := h.AddAudio(chunk); err != nil {
			return nil, err
		}
	}
	return h, nil
}

func (h *Hub) AddFrame(frame Frame) error {
	if frame.Seq < 1 || !finite(frame.Time) || len(frame.Row) != defaultFFTBins {
		return errors.New("invalid frame: seq/time/4096-bin row required")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.frames = append(h.frames, cloneFrame(frame))
	if len(h.frames) > maxFrames {
		h.frames = append([]Frame(nil), h.frames[len(h.frames)-maxFrames:]...)
	}
	return nil
}
func (h *Hub) AddRecord(r Record) error {
	if r.ID < 0 || r.Channel < 1 || r.Channel > 22 || !finite(r.Start) || (r.End != nil && (!finite(*r.End) || *r.End < r.Start)) {
		return errors.New("invalid conversation record")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.records = append(h.records, r)
	sort.SliceStable(h.records, func(i, j int) bool { return h.records[i].Start < h.records[j].Start })
	return nil
}
func (h *Hub) AddAudio(c Chunk) error {
	if c.Seq < 1 || len(c.PCM) == 0 || len(c.PCM)%2 != 0 {
		return errors.New("invalid PCM chunk")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.audio = append(h.audio, Chunk{Seq: c.Seq, PCM: append([]byte(nil), c.PCM...)})
	if len(h.audio) > maxAudioChunks {
		h.audio = append([]Chunk(nil), h.audio[len(h.audio)-maxAudioChunks:]...)
	}
	h.cond.Broadcast()
	return nil
}
func (h *Hub) SetSquelch(v float64) error {
	if !finite(v) || v < -120 || v > 0 {
		return errors.New("squelch must be in [-120, 0]")
	}
	h.mu.Lock()
	h.squelch = v
	h.mu.Unlock()
	return nil
}
func (h *Hub) Squelch() float64 { h.mu.RLock(); defer h.mu.RUnlock(); return h.squelch }
func (h *Hub) Snapshot() Snapshot {
	h.mu.RLock()
	defer h.mu.RUnlock()
	frames := make([]Frame, len(h.frames))
	for i, v := range h.frames {
		frames[i] = cloneFrame(v)
	}
	records := make([]Record, len(h.records))
	copy(records, h.records)
	audio := make([]Chunk, len(h.audio))
	for i, v := range h.audio {
		audio[i] = Chunk{Seq: v.Seq, PCM: append([]byte(nil), v.PCM...)}
	}
	start, end := h.timelineBoundsLocked()
	return Snapshot{CenterHz: h.centerHz, SampleRate: h.sampleRate, AudioRate: h.audioRate, Archived: h.archived, SessionLabel: h.sessionLabel,
		Frames: frames, Records: records, Audio: audio, Timeline: Timeline{Start: start, End: end, Live: !h.archived, CanLiveAudio: !h.archived}}
}

// Summary returns metadata and timeline bounds without copying retained rows.
func (h *Hub) Summary() Snapshot {
	h.mu.RLock()
	defer h.mu.RUnlock()
	start, end := h.timelineBoundsLocked()
	return Snapshot{CenterHz: h.centerHz, SampleRate: h.sampleRate, AudioRate: h.audioRate, SessionLabel: h.sessionLabel,
		Archived: h.archived, Timeline: Timeline{Start: start, End: end, Live: !h.archived, CanLiveAudio: !h.archived}}
}

func (h *Hub) Updates(after int64, since float64) ([]Frame, []Record, Timeline) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	selected := make([]Frame, 0, 800)
	for _, f := range h.frames {
		if f.Seq > after {
			selected = append(selected, f)
		}
	}
	maxRows := 100
	if after == 0 {
		maxRows = 800
	}
	if len(selected) > maxRows {
		selected = selected[len(selected)-maxRows:]
	}
	rowSince := since
	if after == 0 && len(selected) > 0 && selected[0].Time > rowSince {
		rowSince = selected[0].Time
	}
	records := make([]Record, 0)
	for _, rec := range h.records {
		if rec.End == nil || *rec.End >= rowSince {
			records = append(records, cloneRecord(rec))
		}
	}
	start, end := h.timelineBoundsLocked()
	return cloneFrames(selected), records, Timeline{Start: start, End: end, Live: !h.archived, CanLiveAudio: !h.archived}
}

func (h *Hub) History(before float64, limit int) ([]Frame, []Record, bool, Timeline) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	selected := make([]Frame, 0)
	for _, f := range h.frames {
		if f.Time < before {
			selected = append(selected, f)
		}
	}
	if len(selected) > limit {
		selected = selected[len(selected)-limit:]
	}
	start, end := h.timelineBoundsLocked()
	timeline := Timeline{Start: start, End: end, Live: !h.archived, CanLiveAudio: !h.archived}
	if len(selected) == 0 {
		return nil, nil, false, timeline
	}
	floor := selected[0].Time
	records := make([]Record, 0)
	for _, rec := range h.records {
		re := before
		if rec.End != nil {
			re = *rec.End
		}
		if rec.Start <= before && re >= floor {
			records = append(records, cloneRecord(rec))
		}
	}
	return cloneFrames(selected), records, selected[0].Time > start+1e-6, timeline
}

func (h *Hub) LiveAfter(after int64) ([]Chunk, int64) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	chunks := make([]Chunk, 0, 20)
	latest := int64(0)
	if len(h.audio) > 0 {
		latest = h.audio[len(h.audio)-1].Seq
	}
	for _, c := range h.audio {
		if c.Seq > after {
			chunks = append(chunks, Chunk{Seq: c.Seq, PCM: append([]byte(nil), c.PCM...)})
		}
	}
	if len(chunks) > 20 {
		chunks = chunks[len(chunks)-20:]
	}
	return chunks, latest
}

func (h *Hub) AudioAfter(after int64) []Chunk {
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make([]Chunk, 0, 5)
	for _, c := range h.audio {
		if c.Seq > after {
			out = append(out, Chunk{Seq: c.Seq, PCM: append([]byte(nil), c.PCM...)})
		}
	}
	return out
}

func (h *Hub) ChannelRecords(channel int) []Record {
	h.mu.RLock()
	defer h.mu.RUnlock()
	var out []Record
	for _, r := range h.records {
		if r.Channel == channel {
			out = append(out, cloneRecord(r))
		}
	}
	return out
}

func (h *Hub) FindRecord(id int64) (Record, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, r := range h.records {
		if r.ID == id {
			return cloneRecord(r), true
		}
	}
	return Record{}, false
}
func (h *Hub) timelineBoundsLocked() (float64, float64) {
	if len(h.frames) > 0 {
		return h.frames[0].Time, h.frames[len(h.frames)-1].Time
	}
	t := float64(h.started.UnixNano()) / 1e9
	return t, t
}
func (h *Hub) Close() {
	h.mu.Lock()
	if !h.closed {
		h.closed = true
		close(h.closeCh)
		h.cond.Broadcast()
	}
	h.mu.Unlock()
}

// StartSynthetic creates a low-cost, real-time dashboard fixture. It exercises
// the same source ingestion contract but is not a radio/DMA emulator.
func (h *Hub) StartSynthetic() {
	go func() {
		ticker := time.NewTicker(50 * time.Millisecond)
		audioTicker := time.NewTicker(20 * time.Millisecond)
		defer ticker.Stop()
		defer audioTicker.Stop()
		for {
			select {
			case <-h.closeCh:
				return
			case now := <-ticker.C:
				h.syntheticFrame(now)
			case now := <-audioTicker.C:
				h.syntheticAudio(now)
			}
		}
	}()
}

// StartFixtureReplay repeats the fixture's initial PCM ring as a deterministic
// live producer. It is opt-in so normal fixture API responses remain immutable.
func (h *Hub) StartFixtureReplay() {
	h.mu.RLock()
	seed := make([][]byte, len(h.audio))
	for i, c := range h.audio {
		seed[i] = append([]byte(nil), c.PCM...)
	}
	h.mu.RUnlock()
	if len(seed) == 0 {
		return
	}
	go func() {
		ticker := time.NewTicker(20 * time.Millisecond)
		defer ticker.Stop()
		i := 0
		for {
			select {
			case <-h.closeCh:
				return
			case <-ticker.C:
				h.mu.RLock()
				seq := int64(1)
				if n := len(h.audio); n > 0 {
					seq = h.audio[n-1].Seq + 1
				}
				h.mu.RUnlock()
				_ = h.AddAudio(Chunk{Seq: seq, PCM: seed[i%len(seed)]})
				i++
			}
		}
	}()
}
func (h *Hub) syntheticFrame(now time.Time) {
	seq := int64(1)
	h.mu.RLock()
	if n := len(h.frames); n > 0 {
		seq = h.frames[n-1].Seq + 1
	}
	h.mu.RUnlock()
	row := make([]byte, defaultFFTBins)
	phase := float64(seq) * 0.17
	for i := range row {
		noise := int((math.Sin(float64(i)*.71+phase) + 1) * 4)
		row[i] = byte(20 + noise)
	}
	// Fixed narrow peaks on several channel locations create visible test bins.
	for _, bin := range []int{385, 566, 700, 1210, 1330, 1730, 2100, 2450, 2790, 3400} {
		if bin >= 0 && bin < len(row) {
			row[bin] = 210
			if bin > 0 {
				row[bin-1] = 120
			}
			if bin+1 < len(row) {
				row[bin+1] = 120
			}
		}
	}
	_ = h.AddFrame(Frame{Seq: seq, Time: float64(now.UnixNano()) / 1e9, Row: row})
}
func (h *Hub) syntheticAudio(now time.Time) {
	seq := int64(1)
	h.mu.RLock()
	if n := len(h.audio); n > 0 {
		seq = h.audio[n-1].Seq + 1
	}
	h.mu.RUnlock()
	pcm := make([]byte, h.audioRate/50*2)
	// Deterministic low-level tone, mostly silence to exercise live playback path.
	if (now.Unix()/4)%3 == 0 {
		for i := 0; i < len(pcm)/2; i++ {
			v := int16(1800 * math.Sin(2*math.Pi*440*float64(i)/float64(h.audioRate)))
			pcm[2*i] = byte(v)
			pcm[2*i+1] = byte(uint16(v) >> 8)
		}
	}
	_ = h.AddAudio(Chunk{Seq: seq, PCM: pcm})
}

func cloneFrame(f Frame) Frame {
	return Frame{Seq: f.Seq, Time: f.Time, Row: append([]byte(nil), f.Row...)}
}
func cloneFrames(frames []Frame) []Frame {
	out := make([]Frame, len(frames))
	for i, f := range frames {
		out[i] = cloneFrame(f)
	}
	return out
}
func cloneRecord(r Record) Record {
	if r.End != nil {
		v := *r.End
		r.End = &v
	}
	return r
}
func finite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) }
