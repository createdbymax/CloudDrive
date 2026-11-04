// CloudDrive addition (2026-11-03): bounded experimental XDR decoding.
// SPDX-License-Identifier: Apache-2.0

package nfs

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	xdr2 "github.com/rasky/go-xdr/xdr2"
	"testing"
)

func TestBoundedOpaqueRejectsClaimBeforeReadingPayload(t *testing.T) {
	for _, size := range []uint32{(1 << 20) + 1, 0x7fffffff, 0xffffffff} {
		var header [4]byte
		binary.BigEndian.PutUint32(header[:], size)
		reader := bytes.NewReader(header[:])
		data, err := readOpaqueBounded(reader)
		if err == nil || len(data) != 0 {
			t.Fatalf("accepted oversized claim %d", size)
		}
		if reader.Len() != 0 {
			t.Fatal("claim header was not consumed")
		}
	}
}

func TestBoundedOpaqueAcceptsMaximumNativeWrite(t *testing.T) {
	expected := bytes.Repeat([]byte{0x63}, 1<<20)
	var encoded bytes.Buffer
	if _, err := xdr2.Marshal(&encoded, expected); err != nil {
		t.Fatal(err)
	}
	data, err := readOpaqueBounded(&encoded)
	if err != nil || !bytes.Equal(data, expected) {
		t.Fatalf("valid native write rejected: %v", err)
	}
}

func TestHeaderBoundRejectsOversizedCredentialBeforeData(t *testing.T) {
	var encoded bytes.Buffer
	// The RPC header: version, program, version, procedure, auth flavor and
	// auth opaque length. No attacker-controlled payload is needed for rejection.
	for _, value := range []uint32{2, 100003, 3, 7, 1, 4097} {
		binary.Write(&encoded, binary.BigEndian, value)
	}
	var header struct {
		Version, Program, ProgramVersion, Procedure uint32
		Auth                                        struct {
			Flavor uint32
			Data   []byte
		}
		Verifier struct {
			Flavor uint32
			Data   []byte
		}
	}
	if err := readBoundedLimit(&encoded, &header, 4096); err == nil {
		t.Fatal("oversized RPC credential accepted")
	}
}

func TestOversizedRPCRecordRejectedBeforeDecode(t *testing.T) {
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], 0x80000000|(3<<20))
	var connection conn
	if _, err := connection.readRequestHeader(context.Background(), bufio.NewReader(bytes.NewReader(header[:]))); err == nil {
		t.Fatal("oversized record accepted")
	}
}
