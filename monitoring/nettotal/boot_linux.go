package nettotal

import (
	"os"
	"strings"
)

func BootID() (string, error) {
	b, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	return strings.TrimSpace(string(b)), err
}
