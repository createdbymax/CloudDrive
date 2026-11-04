package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
)

type LocalStore struct{ dir string }

func NewLocalStore(dir string) (ChunkStore, error) {
	if !filepath.IsAbs(dir) {
		return nil, errors.New("remote fixture directory must be absolute")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	return &LocalStore{dir}, nil
}
func (s *LocalStore) path(key string) (string, error) {
	if strings.Contains(key, "..") || strings.HasPrefix(key, "/") || strings.ContainsAny(key, "\\\x00") {
		return "", os.ErrInvalid
	}
	return filepath.Join(s.dir, key), nil
}
func (s *LocalStore) Put(ctx context.Context, key string, p []byte) error {
	if len(p) > MaxChunk {
		return os.ErrInvalid
	}
	return s.Publish(ctx, key, int64(len(p)), bytes.NewReader(p))
}
func (s *LocalStore) Get(ctx context.Context, key string) ([]byte, error) {
	path, err := s.path(key)
	if err != nil {
		return nil, err
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, MaxChunk+1))
	if len(data) > MaxChunk {
		return nil, errors.New("oversized chunk")
	}
	return data, err
}
func (s *LocalStore) Publish(ctx context.Context, key string, size int64, r io.Reader) error {
	path, err := s.path(key)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".pending-")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	buf := make([]byte, 128<<10)
	n, err := io.CopyBuffer(f, io.LimitReader(r, size+1), buf)
	if err == nil && n != size {
		err = io.ErrUnexpectedEOF
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err == nil {
		err = syncDirectory(filepath.Dir(path))
	}
	return err
}
