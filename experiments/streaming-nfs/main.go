package main

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	nfs "github.com/willscott/go-nfs"
	"github.com/willscott/go-nfs/helpers"
)

type cappedListener struct {
	net.Listener
	slots chan struct{}
}
type cappedConn struct {
	net.Conn
	once    sync.Once
	release func()
}

func (c *cappedConn) Close() error { err := c.Conn.Close(); c.once.Do(c.release); return err }
func (l *cappedListener) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		select {
		case l.slots <- struct{}{}:
			return &cappedConn{Conn: c, release: func() { <-l.slots }}, nil
		default:
			c.Close()
		}
	}
}
func loopbackListen(address string) (net.Listener, error) {
	host, _, err := net.SplitHostPort(address)
	if err != nil || host != "127.0.0.1" {
		return nil, errors.New("only literal127.0.0.1 listeners are allowed")
	}
	return net.Listen("tcp", address)
}
func main() {
	state := flag.String("state", "", "private experiment state directory (required)")
	nfsAddress := flag.String("addr", "127.0.0.1:0", "loopback NFS address")
	controlAddress := flag.String("control", "127.0.0.1:0", "loopback authenticated experiment control")
	kind := flag.String("store", "local", "local or s3 synthetic store")
	remote := flag.String("remote-dir", "", "separate synthetic local store directory")
	endpoint := flag.String("endpoint", "", "loopback syntheticS3 endpoint")
	bucket := flag.String("bucket", "fixture", "syntheticS3 bucket")
	prefix := flag.String("prefix", "streaming-experiment", "syntheticS3 namespace")
	maxManifest := flag.Int64("max-manifest-bytes", 16<<20, "aggregate journal metadata budget (candidate+current up to2x)")
	crashAfterPut := flag.Bool("crash-after-put", false, "isolated crash injection: exit86 after first committed chunk beforejournal")
	flag.Parse()
	if *state == "" || !filepath.IsAbs(*state) {
		log.Fatal("--state absolute experiment directory required")
	}
	token := os.Getenv("STREAMING_CONTROL_TOKEN")
	if len(token) < 24 {
		log.Fatal("STREAMING_CONTROL_TOKEN requires24syntheticcharacters")
	}
	if err := os.MkdirAll(*state, 0700); err != nil {
		log.Fatal(err)
	}
	lock, err := os.OpenFile(filepath.Join(*state, "owner.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		log.Fatal(err)
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		log.Fatal("experiment state alreadyowned")
	}
	var store ChunkStore
	var binding string
	switch *kind {
	case "local":
		if *remote == "" {
			log.Fatal("--remote-dir required")
		}
		store, err = NewLocalStore(*remote)
		binding = "local:" + filepath.Clean(*remote)
	case "s3":
		store, err = NewS3Store(*endpoint, *bucket, *prefix)
		binding = "s3:" + *endpoint + "/" + *bucket + "/" + *prefix
	default:
		log.Fatal("unsupported experiment store")
	}
	if err != nil {
		log.Fatal(err)
	}
	engine, err := OpenEngine(*state, store, binding, *maxManifest)
	if err != nil {
		log.Fatal(err)
	}
	if *crashAfterPut {
		engine.afterPut = func() { os.Exit(86) }
	}
	listener, err := loopbackListen(*nfsAddress)
	if err != nil {
		log.Fatal(err)
	}
	controls, err := loopbackListen(*controlAddress)
	if err != nil {
		log.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			http.Error(w, "method", 405)
			return
		}
		json.NewEncoder(w).Encode(engine.Stats())
	})
	mux.HandleFunc("/publish", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			http.Error(w, "method", 405)
			return
		}
		name, key := r.URL.Query().Get("name"), r.URL.Query().Get("key")
		if !validName(name) || !strings.HasPrefix(key, "ordinary/") || !validName(strings.TrimPrefix(key, "ordinary/")) {
			http.Error(w, "invalid synthetic name/key", 400)
			return
		}
		if err := engine.Publish(name, key); err != nil {
			http.Error(w, "publication failed", 502)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"published": true, "key": key})
	})
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+token)) != 1 {
			http.Error(w, "unauthorized", 401)
			return
		}
		mux.ServeHTTP(w, r)
	})
	server := http.Server{Handler: handler, ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 11 * time.Minute, MaxHeaderBytes: 8192}
	go func() {
		if err := server.Serve(controls); err != nil {
			log.Print("control server stopped")
		}
	}()
	ready := map[string]any{"ready": true, "nfs": listener.Addr().String(), "control": controls.Addr().String(), "pid": os.Getpid(), "experimental": true, "maxWriteBytes": MaxChunk, "maxManifestBytes": *maxManifest, "maxConnections": 8, "publication": "explicit-control-only"}
	data, _ := json.Marshal(ready)
	fmt.Println(string(data))
	wrapped := &cappedListener{Listener: listener, slots: make(chan struct{}, 8)}
	handlerNFS := helpers.NewCachingHandler(helpers.NewNullAuthHandler(engine), 1024)
	if err = nfs.Serve(wrapped, handlerNFS); err != nil {
		log.Fatal("experimental NFS stopped")
	}
}
