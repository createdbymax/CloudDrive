package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"hash/fnv"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"sync"
	"syscall"
	"time"

	"github.com/go-git/go-billy/v5"
	nfsfile "github.com/willscott/go-nfs/file"
)

const MaxChunk = 1 << 20

type ChunkStore interface {
	Put(context.Context, string, []byte) error
	Get(context.Context, string) ([]byte, error)
	Publish(context.Context, string, int64, io.Reader) error
}

type Extent struct {
	Offset int64
	Length int64
	Key    string
}
type Node struct {
	Size     int64
	Mode     uint32
	Modified time.Time
	Extents  []Extent
}
type Manifest struct {
	Version       int
	StoreBinding  string
	Files         map[string]*Node
	AcceptedBytes uint64
	Writes        uint64
}
type Engine struct {
	mu           sync.Mutex
	state        Manifest
	dir          string
	store        ChunkStore
	maxManifest  int64
	poisoned     error
	afterPut     func()
	beforeCommit func() error
}

type Stats struct {
	Files                  int    `json:"files"`
	AcceptedBytes          uint64 `json:"acceptedBytes"`
	Writes                 uint64 `json:"durableWrites"`
	ManifestBytes          int64  `json:"manifestBytes"`
	ManifestAllocatedBytes int64  `json:"manifestAllocatedBytes"`
	MaxManifestBytes       int64  `json:"maxManifestBytes"`
	MaxWriteBytes          int64  `json:"maxWriteBytes"`
	PayloadStagingBytes    int64  `json:"payloadStagingBytes"`
	Poisoned               bool   `json:"poisoned"`
}

// Local state binds to the exact experiment object-store identity. No owner profile is read.
func OpenEngine(dir string, store ChunkStore, binding string, maxManifest int64) (*Engine, error) {
	if maxManifest < 4096 || maxManifest > 32<<20 {
		return nil, errors.New("manifest budget must be 4KiB..32MiB")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("state must be a private real directory")
	}
	if err = os.Chmod(dir, 0700); err != nil {
		return nil, err
	}
	e := &Engine{dir: dir, store: store, maxManifest: maxManifest, state: Manifest{Version: 1, StoreBinding: binding, Files: map[string]*Node{}}}
	data, err := readManifest(filepath.Join(dir, "manifest.json"), maxManifest)
	if err == nil {
		if int64(len(data)) > maxManifest {
			return nil, errors.New("existing manifest exceeds budget")
		}
		if err = json.Unmarshal(data, &e.state); err != nil {
			return nil, err
		}
		if e.state.Version != 1 || e.state.StoreBinding != binding || e.state.Files == nil {
			return nil, errors.New("journal version/store binding mismatch")
		}
		for name, node := range e.state.Files {
			if !validName(name) || node == nil || node.Size < 0 || node.Size > 1<<50 {
				return nil, errors.New("invalid journal node")
			}
			for _, x := range node.Extents {
				if x.Offset < 0 || x.Offset > 1<<50 || x.Length <= 0 || x.Length > MaxChunk || x.Offset > node.Size-x.Length || !validChunkKey(x.Key) {
					return nil, errors.New("invalid journal extent")
				}
			}
		}
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	// A leftover candidate was never acknowledged. Immutable remote chunks remain untouched.
	if err = os.Remove(filepath.Join(dir, "manifest.next")); err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	return e, nil
}

// Check and limit before allocation, including an existing/corrupt journal.
func readManifest(path string, limit int64) ([]byte, error) {
	entry, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !entry.Mode().IsRegular() || entry.Size() > limit {
		return nil, errors.New("existing manifest exceeds budget or is not regular")
	}
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() || st.Size() > limit {
		return nil, errors.New("existing manifest exceeds budget or is not regular")
	}
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, errors.New("existing manifest grew beyond budget")
	}
	return data, nil
}

var namePattern = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,128}$`)

func cleanName(name string) string { return filepath.ToSlash(filepath.Clean("/" + name))[1:] }
func validName(name string) bool   { return namePattern.MatchString(name) && name != "." && name != ".." }
func validChunkKey(key string) bool {
	if len(key) != len("chunks/")+64 || key[:7] != "chunks/" {
		return false
	}
	_, err := hex.DecodeString(key[7:])
	return err == nil
}
func (e *Engine) check() error {
	if e.poisoned != nil {
		return errors.New("journal uncertain; stop and restart fixture for reconciliation")
	}
	return nil
}
func (e *Engine) clone() Manifest {
	s := e.state
	s.Files = make(map[string]*Node, len(e.state.Files))
	for k, v := range e.state.Files {
		n := *v
		n.Extents = append([]Extent(nil), v.Extents...)
		s.Files[k] = &n
	}
	return s
}
func (e *Engine) encode(s Manifest) ([]byte, error) {
	b, err := json.Marshal(s)
	if err == nil && int64(len(b)) > e.maxManifest {
		err = syscall.ENOSPC
	}
	return b, err
}
func syncDirectory(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}
func durableSync(f *os.File) error { return f.Sync() } // Process-crash ordering, not a claimed hardware power-loss guarantee.
func (e *Engine) commit(s Manifest) error {
	b, err := e.encode(s)
	if err != nil {
		return err
	}
	if e.beforeCommit != nil {
		if err = e.beforeCommit(); err != nil {
			return err
		}
	}
	path := filepath.Join(e.dir, "manifest.next")
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	_, err = f.Write(b)
	if err == nil {
		err = durableSync(f)
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(path, filepath.Join(e.dir, "manifest.json"))
	}
	if err == nil {
		err = syncDirectory(e.dir)
	}
	if err != nil {
		e.poisoned = err
		return err
	}
	e.state = s
	return nil
}
func (e *Engine) Stats() Stats {
	e.mu.Lock()
	defer e.mu.Unlock()
	s := Stats{Files: len(e.state.Files), AcceptedBytes: e.state.AcceptedBytes, Writes: e.state.Writes, MaxManifestBytes: e.maxManifest, MaxWriteBytes: MaxChunk, Poisoned: e.poisoned != nil}
	if st, err := os.Stat(filepath.Join(e.dir, "manifest.json")); err == nil {
		s.ManifestBytes = st.Size()
		if v, ok := st.Sys().(*syscall.Stat_t); ok {
			s.ManifestAllocatedBytes = v.Blocks * 512
		}
	}
	return s
}
func (e *Engine) writeAt(name string, p []byte, off int64) (int, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if err := e.check(); err != nil {
		return 0, err
	}
	if off < 0 || len(p) > MaxChunk || off > 1<<50-int64(len(p)) {
		return 0, os.ErrInvalid
	}
	if len(p) == 0 {
		return 0, nil
	}
	if _, ok := e.state.Files[name]; !ok {
		return 0, os.ErrNotExist
	}
	digest := sha256.Sum256(p)
	key := "chunks/" + hex.EncodeToString(digest[:])
	s := e.clone()
	node := s.Files[name]
	node.Extents = append(node.Extents, Extent{off, int64(len(p)), key})
	if end := off + int64(len(p)); end > node.Size {
		node.Size = end
	}
	node.Modified = time.Now()
	s.Writes++
	s.AcceptedBytes += uint64(len(p))
	// Reserve metadata before sending payload. Overflow fails before accepting a byte.
	if _, err := e.encode(s); err != nil {
		return 0, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := e.store.Put(ctx, key, p); err != nil {
		return 0, err
	}
	if e.afterPut != nil {
		e.afterPut()
	}
	if err := e.commit(s); err != nil {
		return 0, err
	}
	return len(p), nil
}
func (e *Engine) readAtLocked(name string, p []byte, off int64) (int, error) {
	if err := e.check(); err != nil {
		return 0, err
	}
	node, ok := e.state.Files[name]
	if !ok {
		return 0, os.ErrNotExist
	}
	if off < 0 || len(p) > MaxChunk {
		return 0, os.ErrInvalid
	}
	if off >= node.Size {
		return 0, io.EOF
	}
	n := len(p)
	if int64(n) > node.Size-off {
		n = int(node.Size - off)
	}
	clear(p[:n])
	// Oldest first: later accepted writes overwrite overlapping earlier ranges.
	for _, x := range node.Extents {
		start := max(off, x.Offset)
		end := min(off+int64(n), x.Offset+x.Length)
		if end <= start {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		data, err := e.store.Get(ctx, x.Key)
		cancel()
		if err != nil {
			return 0, err
		}
		hash := sha256.Sum256(data)
		if len(data) > MaxChunk || "chunks/"+hex.EncodeToString(hash[:]) != x.Key || int64(len(data)) < x.Length {
			return 0, errors.New("chunk integrity mismatch")
		}
		copy(p[start-off:end-off], data[start-x.Offset:end-x.Offset])
	}
	if n < len(p) {
		return n, io.EOF
	}
	return n, nil
}
func (e *Engine) readAt(name string, p []byte, off int64) (int, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.readAtLocked(name, p, off)
}
func (e *Engine) truncate(name string, size int64) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if err := e.check(); err != nil {
		return err
	}
	if size < 0 || size > 1<<50 {
		return os.ErrInvalid
	}
	if _, ok := e.state.Files[name]; !ok {
		return os.ErrNotExist
	}
	s := e.clone()
	node := s.Files[name]
	var keep []Extent
	for _, x := range node.Extents {
		if x.Offset < size {
			if x.Offset+x.Length > size {
				x.Length = size - x.Offset
			}
			keep = append(keep, x)
		}
	}
	node.Extents = keep
	node.Size = size
	node.Modified = time.Now()
	return e.commit(s)
}

// Explicit publication only. Holding the global mutex freezes a consistent version;
// filesystem writes backpressure while remote ordinary-object assembly runs.
func (e *Engine) Publish(name, key string) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if err := e.check(); err != nil {
		return err
	}
	n, ok := e.state.Files[name]
	if !ok {
		return os.ErrNotExist
	}
	reader := &assembledReader{engine: e, name: name}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	return e.store.Publish(ctx, key, n.Size, reader)
}

type assembledReader struct {
	engine *Engine
	name   string
	offset int64
}

func (r *assembledReader) Read(p []byte) (int, error) {
	if len(p) > MaxChunk {
		p = p[:MaxChunk]
	}
	n, err := r.engine.readAtLocked(r.name, p, r.offset)
	r.offset += int64(n)
	return n, err
}

func (e *Engine) Create(name string) (billy.File, error) {
	return e.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0666)
}
func (e *Engine) Open(name string) (billy.File, error) { return e.OpenFile(name, os.O_RDONLY, 0) }
func (e *Engine) OpenFile(name string, flag int, perm os.FileMode) (billy.File, error) {
	name = cleanName(name)
	if !validName(name) {
		return nil, billy.ErrNotSupported
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if err := e.check(); err != nil {
		return nil, err
	}
	_, exists := e.state.Files[name]
	if !exists {
		if flag&os.O_CREATE == 0 {
			return nil, os.ErrNotExist
		}
		s := e.clone()
		s.Files[name] = &Node{Mode: uint32(perm.Perm()), Modified: time.Now()}
		if err := e.commit(s); err != nil {
			return nil, err
		}
	} else if flag&os.O_CREATE != 0 && flag&os.O_EXCL != 0 {
		return nil, os.ErrExist
	}
	if flag&os.O_TRUNC != 0 {
		return nil, billy.ErrNotSupported
	} // Explicit Truncate is journaled; implicit destructive opens fail closed.
	f := &File{engine: e, name: name, writable: flag&(os.O_WRONLY|os.O_RDWR) != 0}
	if flag&os.O_APPEND != 0 {
		f.offset = e.state.Files[name].Size
	}
	return f, nil
}
func (e *Engine) Stat(name string) (os.FileInfo, error) {
	name = cleanName(name)
	e.mu.Lock()
	defer e.mu.Unlock()
	if err := e.check(); err != nil {
		return nil, err
	}
	if name == "" || name == "." {
		return info{name: ".", mode: os.ModeDir | 0777, modified: time.Unix(1, 0)}, nil
	}
	n, ok := e.state.Files[name]
	if !ok {
		return nil, os.ErrNotExist
	}
	return info{name: name, size: n.Size, mode: os.FileMode(n.Mode), modified: n.Modified}, nil
}
func (e *Engine) Lstat(name string) (os.FileInfo, error) { return e.Stat(name) }
func (e *Engine) ReadDir(name string) ([]os.FileInfo, error) {
	if v := cleanName(name); v != "" && v != "." {
		return nil, billy.ErrNotSupported
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	var out []os.FileInfo
	for name, n := range e.state.Files {
		out = append(out, info{name: name, size: n.Size, mode: os.FileMode(n.Mode), modified: n.Modified})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name() < out[j].Name() })
	return out, nil
}
func (e *Engine) Root() string                                { return "/" }
func (e *Engine) Join(parts ...string) string                 { return filepath.Join(parts...) }
func (e *Engine) Chroot(string) (billy.Filesystem, error)     { return nil, billy.ErrNotSupported }
func (e *Engine) MkdirAll(string, os.FileMode) error          { return billy.ErrNotSupported }
func (e *Engine) Rename(string, string) error                 { return billy.ErrNotSupported }
func (e *Engine) Remove(string) error                         { return billy.ErrNotSupported }
func (e *Engine) Symlink(string, string) error                { return billy.ErrNotSupported }
func (e *Engine) Readlink(string) (string, error)             { return "", billy.ErrNotSupported }
func (e *Engine) TempFile(string, string) (billy.File, error) { return nil, billy.ErrNotSupported }
func (e *Engine) Capabilities() billy.Capability {
	return billy.WriteCapability | billy.ReadCapability | billy.ReadAndWriteCapability | billy.SeekCapability | billy.TruncateCapability
}
func (e *Engine) Chmod(name string, mode os.FileMode) error {
	return e.change(name, func(n *Node) { n.Mode = uint32(mode.Perm()) })
}
func (e *Engine) Chown(name string, uid, gid int) error {
	if (uid != -1 && uid != os.Getuid()) || (gid != -1 && gid != os.Getgid()) {
		return os.ErrPermission
	}
	_, err := e.Stat(name)
	return err
}
func (e *Engine) Lchown(name string, uid, gid int) error { return e.Chown(name, uid, gid) }
func (e *Engine) Chtimes(name string, atime, mtime time.Time) error {
	return e.change(name, func(n *Node) { n.Modified = mtime })
}
func (e *Engine) change(name string, fn func(*Node)) error {
	name = cleanName(name)
	if name == "" || name == "." {
		return nil
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if err := e.check(); err != nil {
		return err
	}
	if _, ok := e.state.Files[name]; !ok {
		return os.ErrNotExist
	}
	s := e.clone()
	fn(s.Files[name])
	return e.commit(s)
}

type info struct {
	name     string
	size     int64
	mode     os.FileMode
	modified time.Time
}

func (i info) Name() string       { return i.name }
func (i info) Size() int64        { return i.size }
func (i info) Mode() os.FileMode  { return i.mode }
func (i info) ModTime() time.Time { return i.modified }
func (i info) IsDir() bool        { return i.mode.IsDir() }
func (i info) Sys() any {
	h := fnv.New64a()
	h.Write([]byte(i.name))
	return nfsfile.FileInfo{Nlink: 1, UID: uint32(os.Getuid()), GID: uint32(os.Getgid()), Fileid: h.Sum64()}
}

// There are no locally staged data blocks; manifest allocation is separately reported.
func (i info) AllocatedBytes() uint64 { return 0 }

type File struct {
	engine   *Engine
	name     string
	offset   int64
	writable bool
	closed   bool
}

func (f *File) Name() string { return f.name }
func (f *File) Write(p []byte) (int, error) {
	if f.closed || !f.writable {
		return 0, os.ErrPermission
	}
	n, err := f.engine.writeAt(f.name, p, f.offset)
	f.offset += int64(n)
	return n, err
}
func (f *File) Read(p []byte) (int, error) {
	n, err := f.ReadAt(p, f.offset)
	f.offset += int64(n)
	return n, err
}
func (f *File) ReadAt(p []byte, off int64) (int, error) {
	if f.closed {
		return 0, os.ErrClosed
	}
	return f.engine.readAt(f.name, p, off)
}
func (f *File) Seek(off int64, whence int) (int64, error) {
	if f.closed {
		return 0, os.ErrClosed
	}
	var next int64
	switch whence {
	case io.SeekStart:
		next = off
	case io.SeekCurrent:
		next = f.offset + off
	case io.SeekEnd:
		st, err := f.engine.Stat(f.name)
		if err != nil {
			return 0, err
		}
		next = st.Size() + off
	default:
		return 0, os.ErrInvalid
	}
	if next < 0 {
		return 0, os.ErrInvalid
	}
	f.offset = next
	return next, nil
}
func (f *File) Close() error  { f.closed = true; return nil } // NOT a publication signal: go-nfs closes once per RPC.
func (f *File) Lock() error   { return billy.ErrNotSupported }
func (f *File) Unlock() error { return billy.ErrNotSupported }
func (f *File) Truncate(size int64) error {
	if f.closed || !f.writable {
		return os.ErrPermission
	}
	return f.engine.truncate(f.name, size)
}

var _ billy.Filesystem = (*Engine)(nil)
var _ billy.Change = (*Engine)(nil)
