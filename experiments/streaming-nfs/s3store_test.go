package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testS3Credentials(t *testing.T) {
	t.Helper()
	t.Setenv("STREAMING_S3_ACCESS_KEY", "fixture")
	t.Setenv("STREAMING_S3_SECRET_KEY", "synthetic-streaming-fixture-secret")
}
func TestS3StoreRejectsExternalOrAmbiguousEndpoints(t *testing.T) {
	testS3Credentials(t)
	for _, endpoint := range []string{"https://127.0.0.1:9000", "http://localhost:9000", "http://127.0.0.2:9000", "http://example.com:9000", "http://127.0.0.1", "http://user@127.0.0.1:9000", "http://127.0.0.1:9000/path", "http://127.0.0.1:9000?token=secret"} {
		if _, err := NewS3Store(endpoint, "bucket", "fixture"); err == nil {
			t.Errorf("accepted endpoint %s", endpoint)
		}
	}
	for _, prefix := range []string{"", "/fixture", "fixture/..", "fixture//other", "../outside", "fixture\\other"} {
		if _, err := NewS3Store("http://127.0.0.1:9000", "bucket", prefix); err == nil {
			t.Errorf("accepted prefix %q", prefix)
		}
	}
}
func TestS3BoundsAndRedirects(t *testing.T) {
	testS3Credentials(t)
	redirected := false
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { redirected = true }))
	defer destination.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/oversized") {
			w.Write(bytes.Repeat([]byte("x"), s3ChunkLimit+1))
			return
		}
		http.Redirect(w, r, destination.URL, http.StatusTemporaryRedirect)
	}))
	defer server.Close()
	store, err := NewS3Store(server.URL, "bucket", "fixture")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put(context.Background(), "chunk/x", make([]byte, s3ChunkLimit+1)); err == nil {
		t.Fatal("oversize PUT accepted")
	}
	if _, err := store.Get(context.Background(), "oversized"); err == nil {
		t.Fatal("oversize GET accepted")
	}
	if _, err := store.Get(context.Background(), "redirect"); err == nil {
		t.Fatal("redirect accepted")
	}
	if redirected {
		t.Fatal("followed redirect")
	}
	if _, err := store.Get(context.Background(), "../outside"); err == nil {
		t.Fatal("unsafe key accepted")
	}
}

func TestS3StoreRealLoopbackMultipartRoundTrip(t *testing.T) {
	testS3Credentials(t)
	binary, err := filepath.Abs("../../build/backend/rclone")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(binary); err != nil {
		t.Fatalf("required bundled real S3 fixture server unavailable: %v", err)
	}
	root := t.TempDir()
	backend := filepath.Join(root, "backend")
	if err := os.MkdirAll(filepath.Join(backend, "bucket"), 0700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	listener.Close()
	log, err := os.Create(filepath.Join(root, "server.log"))
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	command := exec.Command(binary, "serve", "s3", backend, "--addr", address, "--config", "/dev/null")
	command.Env = []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + root, "RCLONE_AUTH_KEY=\"fixture,synthetic-streaming-fixture-secret\""}
	command.Stdout = log
	command.Stderr = log
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	stopped := make(chan error, 1)
	go func() { stopped <- command.Wait() }()
	t.Cleanup(func() {
		command.Process.Signal(os.Interrupt)
		select {
		case <-stopped:
		case <-time.After(3 * time.Second):
			command.Process.Kill()
			<-stopped
		}
	})
	endpoint := "http://" + address
	storeRaw, err := NewS3Store(endpoint, "bucket", "streaming-test")
	if err != nil {
		t.Fatal(err)
	}
	store := storeRaw.(*s3Store)
	defer store.client.CloseIdleConnections()
	deadline := time.Now().Add(8 * time.Second)
	for {
		if conn, err := net.DialTimeout("tcp", address, 100*time.Millisecond); err == nil {
			conn.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("loopback S3 did not start")
		}
		time.Sleep(30 * time.Millisecond)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	chunk := bytes.Repeat([]byte("synthetic-chunk"), 4096)
	if err := store.Put(ctx, "chunk/abc", chunk); err != nil {
		t.Fatal(err)
	}
	got, err := store.Get(ctx, "chunk/abc")
	if err != nil || !bytes.Equal(got, chunk) {
		t.Fatal("chunk round trip mismatch", err)
	}
	store.secret = "wrong-synthetic-secret"
	if _, err := store.Get(ctx, "chunk/abc"); err == nil {
		t.Fatal("server accepted an invalid signature")
	}
	store.secret = "synthetic-streaming-fixture-secret"
	// Three-part publication with a short final part; no source-sized adapter buffer.
	payload := bytes.Repeat([]byte("bounded-streaming-fixture"), (19<<20)/len("bounded-streaming-fixture"))
	old := []byte("previous committed content")
	if err := store.Put(ctx, "ordinary/file.bin", old); err != nil {
		t.Fatal(err)
	}
	if err := store.Publish(ctx, "ordinary/file.bin", int64(len(payload)), bytes.NewReader(payload)); err != nil {
		t.Fatal(err)
	}
	actual, err := os.ReadFile(filepath.Join(backend, "bucket", "streaming-test", "ordinary", "file.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if sha256.Sum256(actual) != sha256.Sum256(payload) {
		t.Fatal("independent published bytes differ")
	}
	if err := store.Put(ctx, "ordinary/preserve.bin", old); err != nil {
		t.Fatal(err)
	}
	// A short producer aborts only its new multipart session and leaves old bytes.
	err = store.Publish(ctx, "ordinary/preserve.bin", int64(s3PublishPartSize+1), bytes.NewReader(chunk))
	var failed *S3PublishError
	if !errors.As(err, &failed) || failed.UploadID == "" || failed.AbortFailed {
		t.Fatalf("failed publication lacked successful abort identity: %v", err)
	}
	got, err = store.Get(ctx, "ordinary/preserve.bin")
	if err != nil || !bytes.Equal(got, old) {
		t.Fatal("failure replaced prior object", err)
	}
	if err := store.Publish(ctx, "ordinary/empty.bin", 0, bytes.NewReader(nil)); err != nil {
		t.Fatal(err)
	}
	got, err = store.Get(ctx, "ordinary/empty.bin")
	if err != nil || len(got) != 0 {
		t.Fatal("empty publication mismatch", err)
	}
	// Excess bytes also abort rather than silently publishing an incorrect length.
	err = store.Publish(ctx, "ordinary/preserve.bin", 1, io.MultiReader(bytes.NewReader([]byte("ab"))))
	if !errors.As(err, &failed) || failed.AbortFailed {
		t.Fatal("oversize producer was not rejected with abort", err)
	}
	got, err = store.Get(ctx, "ordinary/preserve.bin")
	if err != nil || !bytes.Equal(got, old) {
		t.Fatal("oversize source replaced prior object", err)
	}
}
