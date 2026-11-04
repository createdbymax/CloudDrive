# CloudDrive modifications to go-nfs

This directory contains go-nfs v0.0.4, licensed under Apache-2.0. The original LICENSE and source notices are retained. No upstream NOTICE file was present in the pinned source archive.

CloudDrive modified the following source files on November 3, 2026 for the isolated streaming experiment. Changes include bounded RPC/XDR decoding, bounded read/write advertisements, connection cleanup, write-error translation and physical-allocation attributes. This is not an unmodified upstream release.

- `conn.go`
- `file.go`
- `mount.go`
- `nfs_onaccess.go`
- `nfs_oncommit.go`
- `nfs_oncreate.go`
- `nfs_onfsinfo.go`
- `nfs_onfsstat.go`
- `nfs_ongetattr.go`
- `nfs_onlink.go`
- `nfs_onlookup.go`
- `nfs_onmkdir.go`
- `nfs_onmknod.go`
- `nfs_onpathconf.go`
- `nfs_onread.go`
- `nfs_onreaddir.go`
- `nfs_onreaddirplus.go`
- `nfs_onreadlink.go`
- `nfs_onremove.go`
- `nfs_onrename.go`
- `nfs_onsetattr.go`
- `nfs_onsymlink.go`
- `nfs_onwrite.go`

Added Apache-2.0 files:

- `bounded_decode.go`
- `bounded_decode_test.go`

The ordinary CloudDrive Swift app and the experimental engine outside this directory have their own project license. This notice does not relicense upstream go-nfs.
