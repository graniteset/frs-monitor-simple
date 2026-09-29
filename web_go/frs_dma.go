package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"time"
)

const (
	frsDMAWordBytes       = 8
	frsDMASamplesPerChunk = 250 // 20 ms at 12.5 ksample/s per channel.
	frsReceiverSampleRate = 6400000
)

// FRSRecord is the bridge's Q1.15 mono audio sample tagged with the FRS ID
// (1..22), decoded from one 21-bit record in the DMA payload.
type FRSRecord struct {
	Channel int
	Sample  int16
}

// DecodeFRSDMAWord decodes the current RTL ABI: two 21-bit records in bits
// [20:0] and [41:21], reserved [61:42] = 0, and count [63:62] = 2.
// The DMA buffer is little-endian, matching the Zynq ARM's normal byte order.
func DecodeFRSDMAWord(b []byte) ([2]FRSRecord, error) {
	var records [2]FRSRecord
	if len(b) != frsDMAWordBytes {
		return records, fmt.Errorf("FRS DMA word is %d bytes, want 8", len(b))
	}
	w := binary.LittleEndian.Uint64(b)
	if w>>62 != 2 {
		return records, fmt.Errorf("unsupported FRS DMA record count %d", w>>62)
	}
	if (w>>42)&0xfffff != 0 {
		return records, errors.New("nonzero reserved bits in FRS DMA word")
	}
	for i := range records {
		packed := (w >> (21 * i)) & 0x1fffff
		ch := int((packed >> 16) & 0x1f)
		if ch < 1 || ch > 22 {
			return records, fmt.Errorf("invalid FRS channel tag %d", ch)
		}
		records[i] = FRSRecord{Channel: ch, Sample: int16(uint16(packed))}
	}
	return records, nil
}

// FRSDMAIngestor converts packed DMA records into the existing dashboard
// source. The capture does not contain IQ or an RF FFT: waterfall rows are
// explicitly audio-activity indicators at channel frequencies, not spectrum.
type FRSDMAIngestor struct {
	hub           *Hub
	start         time.Time
	seq           int64
	buffers       [22][]int16
	active        [22]bool
	activeID      [22]int64
	nextRecordID  int64
	activityFloor float64
	gates         [22]audioRMSGate
}

func NewFRSDMAIngestor(h *Hub) *FRSDMAIngestor {
	i := &FRSDMAIngestor{hub: h, start: time.Now(), activityFloor: 1}
	for n := range i.buffers {
		i.buffers[n] = make([]int16, 0, frsDMASamplesPerChunk)
	}
	h.mu.Lock()
	h.sessionLabel = "FPGA audio activity (not RF spectrum)"
	h.centerHz = defaultCenterHz
	h.sampleRate = frsReceiverSampleRate
	h.mu.Unlock()
	return i
}

// Ingest reads little-endian 64-bit DMA words until EOF. A partial final word
// is an error rather than silently shifting every subsequent record.
func (i *FRSDMAIngestor) Ingest(r io.Reader) error {
	word := make([]byte, frsDMAWordBytes)
	for {
		_, err := io.ReadFull(r, word)
		if err == io.EOF {
			i.flushRemainder()
			return nil
		}
		if err != nil {
			return fmt.Errorf("read FRS DMA stream: %w", err)
		}
		records, err := DecodeFRSDMAWord(word)
		if err != nil {
			return err
		}
		for _, rec := range records {
			buf := &i.buffers[rec.Channel-1]
			*buf = append(*buf, rec.Sample)
		}
		for i.ready() {
			i.flush(frsDMASamplesPerChunk)
		}
	}
}

func (i *FRSDMAIngestor) ready() bool {
	for n := range i.buffers {
		if len(i.buffers[n]) < frsDMASamplesPerChunk {
			return false
		}
	}
	return true
}

func (i *FRSDMAIngestor) flushRemainder() {
	minCount := frsDMASamplesPerChunk
	for n := range i.buffers {
		if len(i.buffers[n]) < minCount {
			minCount = len(i.buffers[n])
		}
	}
	// Compute the end before flush increments the full-window sequence number.
	end := float64(i.start.UnixNano())/1e9 + float64(i.seq*frsDMASamplesPerChunk+int64(minCount))/float64(defaultAudioRate)
	if minCount > 0 {
		i.flush(minCount)
	}
	for n, active := range i.active {
		if active {
			i.hub.EndRecord(i.activeID[n], end)
			i.active[n] = false
		}
	}
}

func (i *FRSDMAIngestor) flush(count int) {
	stamp := float64(i.start.UnixNano())/1e9 + float64(i.seq*frsDMASamplesPerChunk)/float64(defaultAudioRate)
	pcmByChannel := make([][]byte, 22)
	row := make([]byte, defaultFFTBins)
	for n := 0; n < 22; n++ {
		buf := i.buffers[n]
		pcm := make([]byte, count*2)
		squares := float64(0)
		for j, sample := range buf[:count] {
			binary.LittleEndian.PutUint16(pcm[j*2:], uint16(sample))
			squares += float64(sample) * float64(sample)
		}
		rms := 0.0
		if count > 0 {
			rms = math.Sqrt(squares / float64(count))
		}
		floor := math.Max(i.activityFloor, 32768*math.Pow(10, i.hub.Squelch()/20))
		gateOpen := i.gates[n].Update(rms, floor, stamp+float64(count)/float64(defaultAudioRate))
		isActive := gateOpen
		if !gateOpen {
			clear(pcm)
		}
		channel := n + 1
		freq := frsChannelHz[channel-1]
		bin := int(math.Round(float64(freq-(i.hub.centerHz-int64(i.hub.sampleRate/2))) * float64(defaultFFTBins) / float64(i.hub.sampleRate)))
		if bin >= 0 && bin < len(row) {
			row[bin] = 18
			if isActive {
				row[bin] = byte(math.Max(64, math.Min(255, 64+20*math.Log10(1+rms))))
			}
		}
		if isActive {
			row[bin] = max(row[bin], byte(90))
		}
		pcmByChannel[n] = pcm
		_ = i.hub.AddChannelAudio(ChannelChunk{Seq: i.seq*22 + int64(channel), Channel: channel, Start: stamp, PCM: pcm})
		if isActive && !i.active[n] {
			i.nextRecordID++
			if i.nextRecordID < 1 {
				i.nextRecordID = 1
			}
			i.activeID[n] = i.nextRecordID
			_ = i.hub.AddRecord(Record{ID: i.activeID[n], Channel: channel, Frequency: freq, Start: stamp})
			i.active[n] = true
		} else if !isActive && i.active[n] {
			end := stamp
			i.hub.EndRecord(i.activeID[n], end)
			i.active[n] = false
		}
		i.buffers[n] = append(i.buffers[n][:0], i.buffers[n][count:]...)
	}
	// A unity-gain average across non-silent channels avoids the severe clipping
	// of a straight sum while retaining a useful live monitor mix.
	mix := make([]byte, count*2)
	for sample := 0; sample < count; sample++ {
		sum, contributors := 0, 0
		for ch := 0; ch < 22; ch++ {
			v := int(int16(binary.LittleEndian.Uint16(pcmByChannel[ch][sample*2:])))
			if v != 0 {
				sum += v
				contributors++
			}
		}
		if contributors > 0 {
			sum /= contributors
		}
		if sum > 32767 {
			sum = 32767
		}
		if sum < -32768 {
			sum = -32768
		}
		binary.LittleEndian.PutUint16(mix[sample*2:], uint16(int16(sum)))
	}
	i.seq++
	_ = i.hub.AddFrame(Frame{Seq: i.seq, Time: stamp, Row: row})
	_ = i.hub.AddAudio(Chunk{Seq: i.seq, PCM: mix})
}

// audioRMSGate is the userspace fallback for the FPGA's currently-open RF
// squelch. It opens at the selected RMS dBFS floor, closes only below a 3 dB
// lower threshold, and holds open for 200 ms below that close threshold.
type audioRMSGate struct {
	open       bool
	belowSince float64
}

func (g *audioRMSGate) Update(rms, openFloor, timestamp float64) bool {
	openFloor = math.Max(1, openFloor)
	closeFloor := openFloor * math.Pow(10, -3.0/20)
	if !g.open {
		if rms >= openFloor {
			g.open = true
			g.belowSince = 0
		}
		return g.open
	}
	if rms >= closeFloor {
		g.belowSince = 0
		return true
	}
	if g.belowSince == 0 {
		g.belowSince = timestamp
	}
	if timestamp-g.belowSince >= 0.2 {
		g.open = false
		g.belowSince = 0
	}
	return g.open
}

var frsChannelHz = [...]int64{
	462562500, 462587500, 462612500, 462637500, 462662500, 462687500, 462712500,
	467562500, 467587500, 467612500, 467637500, 467662500, 467687500, 467712500,
	462550000, 462575000, 462600000, 462625000, 462650000, 462675000, 462700000, 462725000,
}
