//go:build linux

package chatsend

import "syscall"

type fileIdentity struct {
	dev     uint64
	ino     uint64
	size    int64
	mtimeNs int64
	ctimeNs int64
}

func statIdentity(st *syscall.Stat_t) fileIdentity {
	return fileIdentity{
		dev:     uint64(st.Dev),
		ino:     uint64(st.Ino),
		size:    st.Size,
		mtimeNs: st.Mtim.Nano(),
		ctimeNs: st.Ctim.Nano(),
	}
}
