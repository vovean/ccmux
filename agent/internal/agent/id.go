package agent

import (
	"crypto/rand"
	"encoding/hex"
)

// newID is a random 128-bit identifier, rendered like a UUID so it reads the same as the
// ids the Mac generates and ccmuxd already stores.
func newID() string {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		panic("no entropy available: " + err.Error())
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	hexed := hex.EncodeToString(raw[:])
	return hexed[0:8] + "-" + hexed[8:12] + "-" + hexed[12:16] + "-" +
		hexed[16:20] + "-" + hexed[20:32]
}
