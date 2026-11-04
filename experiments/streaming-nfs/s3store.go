package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

const s3ChunkLimit = 1 << 20
const s3PublishPartSize = 8 << 20
const s3XMLLimit = 64 << 10

type s3Store struct {
	endpoint                       *url.URL
	bucket, prefix, access, secret string
	client                         *http.Client
}

// S3PublishError retains a failed abort's upload identity for explicit recovery.
// Accepted payload remains in the engine's immutable chunks and manifest.
type S3PublishError struct {
	UploadID    string
	AbortFailed bool
	Cause       error
}

func (e *S3PublishError) Error() string {
	return "S3 publication failed; accepted chunks remain retained"
}
func (e *S3PublishError) Unwrap() error { return e.Cause }

// NewS3Store is deliberately confined to a literal loopback HTTP test endpoint.
// It never consumes owner R2 environment variables, ambient proxies or redirects.
func NewS3Store(endpoint, bucket, prefix string) (ChunkStore, error) {
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme != "http" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") || (u.Hostname() != "127.0.0.1" && u.Hostname() != "::1") {
		return nil, errors.New("S3 experiment requires a literal loopback HTTP endpoint")
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil || port < 1 || port > 65535 {
		return nil, errors.New("S3 experiment requires an explicit valid port")
	}
	if !safeS3Key(bucket) || strings.Contains(bucket, "/") || !safeS3Key(prefix) {
		return nil, errors.New("invalid experimental S3 namespace")
	}
	access, secret := os.Getenv("STREAMING_S3_ACCESS_KEY"), os.Getenv("STREAMING_S3_SECRET_KEY")
	if access == "" || secret == "" || strings.ContainsAny(access+secret, "\r\n") {
		return nil, errors.New("synthetic S3 credentials are required")
	}
	transport := &http.Transport{Proxy: nil, DialContext: (&net.Dialer{Timeout: 5 * time.Second, KeepAlive: 15 * time.Second}).DialContext, MaxIdleConns: 4, MaxIdleConnsPerHost: 2, IdleConnTimeout: 20 * time.Second, ResponseHeaderTimeout: 10 * time.Second, DisableCompression: true}
	return &s3Store{endpoint: u, bucket: bucket, prefix: prefix, access: access, secret: secret, client: &http.Client{Transport: transport, Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}

func safeS3Key(key string) bool {
	if key == "" || len(key) > 1024 {
		return false
	}
	for _, part := range strings.Split(key, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
		for _, c := range part {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') {
				return false
			}
		}
	}
	return true
}
func awsEscape(value string) string {
	var b strings.Builder
	const digits = "0123456789ABCDEF"
	for _, c := range []byte(value) {
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.' || c == '~' {
			b.WriteByte(c)
		} else {
			b.WriteByte('%')
			b.WriteByte(digits[c>>4])
			b.WriteByte(digits[c&15])
		}
	}
	return b.String()
}
func canonicalQuery(query url.Values) string {
	keys := make([]string, 0, len(query))
	for k := range query {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var pairs []string
	for _, key := range keys {
		values := append([]string(nil), query[key]...)
		sort.Strings(values)
		for _, value := range values {
			pairs = append(pairs, awsEscape(key)+"="+awsEscape(value))
		}
	}
	return strings.Join(pairs, "&")
}
func shaHex(data []byte) string { d := sha256.Sum256(data); return hex.EncodeToString(d[:]) }
func hmacSHA(key []byte, value string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(value))
	return h.Sum(nil)
}

func (s *s3Store) request(ctx context.Context, method, key string, query url.Values, payload []byte) (*http.Response, error) {
	if !safeS3Key(key) || len(s.prefix)+1+len(key) > 1024 {
		return nil, errors.New("invalid experimental object key")
	}
	u := *s.endpoint
	u.Path = "/" + s.bucket + "/" + s.prefix + "/" + key
	u.RawPath = ""
	u.RawQuery = canonicalQuery(query)
	req, err := http.NewRequestWithContext(ctx, method, u.String(), bytes.NewReader(payload))
	if err != nil {
		return nil, errors.New("could not create S3 request")
	}
	now := time.Now().UTC()
	stamp, day := now.Format("20060102T150405Z"), now.Format("20060102")
	hash := shaHex(payload)
	req.Header.Set("X-Amz-Date", stamp)
	req.Header.Set("X-Amz-Content-Sha256", hash)
	canonical := method + "\n" + u.EscapedPath() + "\n" + u.RawQuery + "\n" + "host:" + u.Host + "\n" + "x-amz-content-sha256:" + hash + "\n" + "x-amz-date:" + stamp + "\n\n" + "host;x-amz-content-sha256;x-amz-date\n" + hash
	scope := day + "/auto/s3/aws4_request"
	stringToSign := "AWS4-HMAC-SHA256\n" + stamp + "\n" + scope + "\n" + shaHex([]byte(canonical))
	k := hmacSHA([]byte("AWS4"+s.secret), day)
	k = hmacSHA(k, "auto")
	k = hmacSHA(k, "s3")
	k = hmacSHA(k, "aws4_request")
	req.Header.Set("Authorization", "AWS4-HMAC-SHA256 Credential="+s.access+"/"+scope+", SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature="+hex.EncodeToString(hmacSHA(k, stringToSign)))
	response, err := s.client.Do(req)
	if err != nil {
		return nil, errors.New("S3 loopback request failed")
	}
	return response, nil
}
func responseBytes(response *http.Response, limit int64) ([]byte, error) {
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil {
		return nil, errors.New("S3 response read failed")
	}
	if int64(len(data)) > limit {
		return nil, errors.New("S3 response exceeded bound")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("S3 request returned HTTP %d", response.StatusCode)
	}
	return data, nil
}
func (s *s3Store) Put(ctx context.Context, key string, payload []byte) error {
	if len(payload) > s3ChunkLimit {
		return errors.New("chunk exceeds 1 MiB bound")
	}
	response, err := s.request(ctx, http.MethodPut, key, nil, payload)
	if err != nil {
		return err
	}
	_, err = responseBytes(response, s3XMLLimit)
	return err
}
func (s *s3Store) Get(ctx context.Context, key string) ([]byte, error) {
	response, err := s.request(ctx, http.MethodGet, key, nil, nil)
	if err != nil {
		return nil, err
	}
	return responseBytes(response, s3ChunkLimit)
}
func (s *s3Store) abort(uploadID, key string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	response, err := s.request(ctx, http.MethodDelete, key, url.Values{"uploadId": {uploadID}}, nil)
	if err != nil {
		return err
	}
	_, err = responseBytes(response, s3XMLLimit)
	return err
}

type completePart struct {
	Number int    `xml:"PartNumber"`
	ETag   string `xml:"ETag"`
}
type completeUpload struct {
	XMLName xml.Name       `xml:"CompleteMultipartUpload"`
	Parts   []completePart `xml:"Part"`
}

func (s *s3Store) Publish(ctx context.Context, key string, size int64, source io.Reader) (result error) {
	if !safeS3Key(key) || size < 0 || size > int64(s3PublishPartSize)*10000 || source == nil {
		return errors.New("invalid bounded publication")
	}
	if size == 0 {
		var extra [1]byte
		n, err := io.ReadFull(source, extra[:])
		if n != 0 || err != io.EOF {
			return errors.New("publication source does not match declared size")
		}
		return s.Put(ctx, key, nil)
	}
	response, err := s.request(ctx, http.MethodPost, key, url.Values{"uploads": {""}}, nil)
	if err != nil {
		return err
	}
	data, err := responseBytes(response, s3XMLLimit)
	if err != nil {
		return err
	}
	var started struct {
		XMLName xml.Name
		ID      string `xml:"UploadId"`
	}
	if err := xml.Unmarshal(data, &started); err != nil {
		return fmt.Errorf("invalid multipart initiation XML: %w", err)
	}
	// rclone's loopback S3 fixture uses InitiateMultipartUpload; AWS uses
	// InitiateMultipartUploadResult. Both must contain a bounded upload ID.
	if (started.XMLName.Local != "InitiateMultipartUploadResult" && started.XMLName.Local != "InitiateMultipartUpload") || started.ID == "" || len(started.ID) > 4096 {
		return errors.New("invalid multipart initiation identity")
	}
	completed := false
	defer func() {
		if !completed {
			abortErr := s.abort(started.ID, key)
			result = &S3PublishError{UploadID: started.ID, AbortFailed: abortErr != nil, Cause: result}
		}
	}()
	buffer := make([]byte, s3PublishPartSize)
	parts := completeUpload{}
	remaining := size
	for number := 1; remaining > 0; number++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		count := int64(len(buffer))
		if remaining < count {
			count = remaining
		}
		if _, err := io.ReadFull(source, buffer[:int(count)]); err != nil {
			return errors.New("publication source ended before declared size")
		}
		response, err := s.request(ctx, http.MethodPut, key, url.Values{"uploadId": {started.ID}, "partNumber": {strconv.Itoa(number)}}, buffer[:int(count)])
		if err != nil {
			return err
		}
		etag := response.Header.Get("ETag")
		if _, err = responseBytes(response, s3XMLLimit); err != nil {
			return err
		}
		if etag == "" || len(etag) > 1024 {
			return errors.New("missing bounded multipart ETag")
		}
		parts.Parts = append(parts.Parts, completePart{Number: number, ETag: etag})
		remaining -= count
	}
	var extra [1]byte
	n, readErr := io.ReadFull(source, extra[:])
	if n != 0 || readErr != io.EOF {
		return errors.New("publication source exceeds declared size or failed at EOF")
	}
	body, err := xml.Marshal(parts)
	if err != nil {
		return errors.New("could not encode multipart completion")
	}
	response, err = s.request(ctx, http.MethodPost, key, url.Values{"uploadId": {started.ID}}, body)
	if err != nil {
		return err
	}
	data, err = responseBytes(response, s3XMLLimit)
	if err != nil {
		return err
	}
	var finish struct {
		XMLName xml.Name `xml:"CompleteMultipartUploadResult"`
		ETag    string   `xml:"ETag"`
	}
	if xml.Unmarshal(data, &finish) != nil || finish.ETag == "" {
		return errors.New("invalid multipart completion response")
	}
	completed = true
	return nil
}
