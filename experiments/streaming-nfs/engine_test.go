package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"
)

type memoryStore struct {
	mu      sync.Mutex
	objects map[string][]byte
	fail    bool
	puts    int
	active  int
	peak    int
	delay   time.Duration
}

func (s *memoryStore) Put(_ context.Context, key string, p []byte) error {
	s.mu.Lock()
	s.puts++
	s.active++
	if s.active > s.peak {
		s.peak = s.active
	}
	fail := s.fail
	s.mu.Unlock()
	time.Sleep(s.delay)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.active--
	if fail {
		return errors.New("fixture offline")
	}
	s.objects[key] = append([]byte(nil), p...)
	return nil
}
func (s *memoryStore) Get(_ context.Context, key string) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.objects[key]
	if !ok {
		return nil, os.ErrNotExist
	}
	return append([]byte(nil), p...), nil
}
func (s *memoryStore) Publish(_ context.Context, key string, size int64, r io.Reader) error {
	p, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	if int64(len(p)) != size {
		return io.ErrUnexpectedEOF
	}
	s.mu.Lock()
	s.objects[key] = p
	s.mu.Unlock()
	return nil
}
func fixture(t *testing.T, budget int64) (*Engine, *memoryStore, string) {
	t.Helper()
	s := &memoryStore{objects: map[string][]byte{}}
	dir := t.TempDir()
	e, err := OpenEngine(dir, s, "fixture", budget)
	if err != nil {
		t.Fatal(err)
	}
	return e, s, dir
}
func create(t *testing.T, e *Engine, name string) {
	t.Helper()
	f, err := e.Create(name)
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
}
func write(t *testing.T, e *Engine, name string, p []byte, off int64) {
	t.Helper()
	n, err := e.writeAt(name, p, off)
	if err != nil || n != len(p) {
		t.Fatalf("write %d %v", n, err)
	}
}
func contents(t *testing.T, e *Engine, name string, size int) []byte {
	t.Helper()
	p := make([]byte, size)
	n, err := e.readAt(name, p, 0)
	if err != nil && err != io.EOF {
		t.Fatal(err)
	}
	return p[:n]
}
func TestAcceptedWritesSurviveRestartAndPublishOrdinaryBytes(t *testing.T) {
	e, s, dir := fixture(t, 1<<20)
	create(t, e, "fixture.bin")
	data := bytes.Repeat([]byte("payload"), 10000)
	write(t, e, "fixture.bin", data, 0)
	e2, err := OpenEngine(dir, s, "fixture", 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(contents(t, e2, "fixture.bin", len(data)), data) {
		t.Fatal("restart mismatch")
	}
	if err = e2.Publish("fixture.bin", "ordinary/final.bin"); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(s.objects["ordinary/final.bin"], data) {
		t.Fatal("publication mismatch")
	}
	if _, err = os.Stat(filepath.Join(dir, "manifest.json")); err != nil {
		t.Fatal(err)
	}
}
func TestRemoteFailureNeverAcknowledgesOrAdvancesManifest(t *testing.T) {
	e, s, _ := fixture(t, 1<<20)
	create(t, e, "file")
	s.fail = true
	n, err := e.writeAt("file", []byte("rejected"), 0)
	if err == nil || n != 0 || e.Stats().AcceptedBytes != 0 {
		t.Fatal("false accepted write")
	}
	if st, _ := e.Stat("file"); st.Size() != 0 {
		t.Fatal("false length")
	}
}
func TestCrashAfterRemotePutBeforeJournalPreservesPreviouslyAcceptedBytes(t *testing.T) {
	e, s, dir := fixture(t, 1<<20)
	create(t, e, "file")
	write(t, e, "file", []byte("accepted"), 0)
	e.afterPut = func() { panic("simulated process death beforejournal") }
	func() { defer func() { _ = recover() }(); e.writeAt("file", []byte("unacknowledged"), 0) }()
	fresh, err := OpenEngine(dir, s, "fixture", 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents(t, fresh, "file", 100)) != "accepted" {
		t.Fatal("unacknowledged mutation appeared")
	}
}
func TestJournalFailureDoesNotAcknowledgeCommittedRemoteChunk(t *testing.T) {
	e, _, dir := fixture(t, 1<<20)
	create(t, e, "file")
	e.beforeCommit = func() error { return syscall.ENOSPC }
	n, err := e.writeAt("file", []byte("remote-only"), 0)
	if n != 0 || !errors.Is(err, syscall.ENOSPC) {
		t.Fatal("false persistent success")
	}
	fresh, err := OpenEngine(dir, e.store, "fixture", 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if fresh.Stats().AcceptedBytes != 0 {
		t.Fatal("journal advanced")
	}
}
func TestRewriteTruncateHolesAndExtension(t *testing.T) {
	e, _, _ := fixture(t, 1<<20)
	create(t, e, "file")
	write(t, e, "file", []byte("abcdef"), 0)
	write(t, e, "file", []byte("XY"), 2)
	if string(contents(t, e, "file", 20)) != "abXYef" {
		t.Fatal("overlap")
	}
	if err := e.truncate("file", 3); err != nil {
		t.Fatal(err)
	}
	if err := e.truncate("file", 8); err != nil {
		t.Fatal(err)
	}
	want := append([]byte("abX"), make([]byte, 5)...)
	if !bytes.Equal(contents(t, e, "file", 8), want) {
		t.Fatal("old truncated bytes reappeared")
	}
	write(t, e, "file", []byte("Z"), 7)
	want[7] = 'Z'
	if !bytes.Equal(contents(t, e, "file", 8), want) {
		t.Fatal("hole mismatch")
	}
}
func TestAggregateBudgetStopsBeforeNewPayloadAdmission(t *testing.T) {
	e, s, _ := fixture(t, 4096)
	create(t, e, "one")
	create(t, e, "two")
	for i := 0; i < 200; i++ {
		before := e.Stats()
		puts := s.puts
		_, err := e.writeAt([]string{"one", "two"}[i%2], []byte{byte(i)}, int64(i))
		if errors.Is(err, syscall.ENOSPC) {
			after := e.Stats()
			if after.AcceptedBytes != before.AcceptedBytes || s.puts != puts {
				t.Fatal("budget admitted payload before failure")
			}
			if after.ManifestBytes > 4096 {
				t.Fatal("budget overshoot")
			}
			return
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	t.Fatal("budget never reached")
}
func TestConcurrentFilesBackpressureSerializeRemoteWrites(t *testing.T) {
	e, s, _ := fixture(t, 1<<20)
	s.delay = 20 * time.Millisecond
	create(t, e, "one")
	create(t, e, "two")
	var wg sync.WaitGroup
	for _, name := range []string{"one", "two"} {
		wg.Add(1)
		go func(n string) {
			defer wg.Done()
			if _, err := e.writeAt(n, []byte("data"), 0); err != nil {
				t.Error(err)
			}
		}(name)
	}
	wg.Wait()
	if s.peak != 1 {
		t.Fatalf("remote concurrency %d", s.peak)
	}
}
func TestUnsupportedMutationsFailClosed(t *testing.T) {
	e, _, _ := fixture(t, 1<<20)
	create(t, e, "one")
	write(t, e, "one", []byte("retained"), 0)
	if e.Remove("one") == nil || e.Rename("one", "two") == nil {
		t.Fatal("unsupported operation accepted")
	}
	if _, err := e.Create("one"); !os.IsExist(err) {
		t.Fatal("recreate silently truncated")
	}
	if string(contents(t, e, "one", 20)) != "retained" {
		t.Fatal("mutation damaged bytes")
	}
}
func TestChunkIntegrityAndBindingFailuresAreExplicit(t *testing.T) {
	e, s, dir := fixture(t, 1<<20)
	create(t, e, "one")
	write(t, e, "one", []byte("correct"), 0)
	for key := range s.objects {
		s.objects[key] = []byte("broken")
	}
	if _, err := e.readAt("one", make([]byte, 7), 0); err == nil {
		t.Fatal("corrupt chunk accepted")
	}
	if _, err := OpenEngine(dir, s, "other-store", 1<<20); err == nil {
		t.Fatal("different store allowed")
	}
}
func TestOversizedWriteFailsBeforeRemoteAllocation(t *testing.T) {
	e, s, _ := fixture(t, 1<<20)
	create(t, e, "one")
	if n, err := e.writeAt("one", make([]byte, MaxChunk+1), 0); n != 0 || err == nil || s.puts != 0 {
		t.Fatal("oversized write admitted")
	}
}

func TestRestartRejectsOversizedManifestBeforeReadingPayload(t *testing.T) {
	dir := t.TempDir()
	f, err := os.Create(filepath.Join(dir, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err = f.Truncate(1 << 30); err != nil {
		t.Fatal(err)
	}
	f.Close()
	store := &memoryStore{objects: map[string][]byte{}}
	if _, err = OpenEngine(dir, store, "fixture", 4096); err == nil {
		t.Fatal("oversized existing journal accepted")
	}
}
func TestRestartRejectsCorruptExtentBounds(t *testing.T) {
	digestKey := "chunks/" + string(bytes.Repeat([]byte("a"), 64))
	cases := []Node{
		{Size: 1<<50 + 1},
		{Size: 10, Extents: []Extent{{Offset: 1 << 62, Length: 1, Key: digestKey}}},
		{Size: 10, Extents: []Extent{{Offset: 9, Length: 2, Key: digestKey}}},
		{Size: 10, Extents: []Extent{{Offset: 0, Length: MaxChunk + 1, Key: digestKey}}},
	}
	for _, node := range cases {
		dir := t.TempDir()
		m := Manifest{Version: 1, StoreBinding: "fixture", Files: map[string]*Node{"file": &node}}
		data, err := json.Marshal(m)
		if err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(filepath.Join(dir, "manifest.json"), data, 0600); err != nil {
			t.Fatal(err)
		}
		if _, err = OpenEngine(dir, &memoryStore{objects: map[string][]byte{}}, "fixture", 4096); err == nil {
			t.Fatal("corrupt extent accepted")
		}
	}
}

func TestRestartRejectsNonRegularManifestWithoutBlocking(t *testing.T) {
	for _, kind := range []string{"symlink", "fifo"} {
		dir := t.TempDir()
		path := filepath.Join(dir, "manifest.json")
		if kind == "fifo" {
			if err := syscall.Mkfifo(path, 0600); err != nil {
				t.Fatal(err)
			}
		} else {
			target := filepath.Join(dir, "synthetic-target")
			if err := os.WriteFile(target, []byte("not a journal"), 0600); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, path); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := OpenEngine(dir, &memoryStore{objects: map[string][]byte{}}, "fixture", 4096); err == nil {
			t.Fatal("nonregular journal accepted")
		}
	}
}
