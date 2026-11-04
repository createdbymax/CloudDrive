// CloudDrive addition (2026-11-03): bounded experimental XDR decoding.
// SPDX-License-Identifier: Apache-2.0

package nfs

import (
	xdr2 "github.com/rasky/go-xdr/xdr2"
	"io"
)

// Experiment-only cap: reject claimed XDR variable lengths before allocation,
// including malicious small RPC records claiming enormous opaque data.
func readBoundedLimit(r io.Reader, v interface{}, limit uint) error {
	_, err := xdr2.UnmarshalLimited(r, v, limit)
	return err
}
func readBounded(r io.Reader, v interface{}) error { return readBoundedLimit(r, v, 1<<20) }
func readOpaqueBounded(r io.Reader) ([]byte, error) {
	var data []byte
	err := readBounded(r, &data)
	return data, err
}
