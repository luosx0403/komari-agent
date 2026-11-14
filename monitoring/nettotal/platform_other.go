//go:build !linux && !darwin

package nettotal

import (
	"fmt"
	"os"
)

func lockFile(f *os.File) error {
	return fmt.Errorf("lifetime network totals support Linux and macOS only")
}
func BootID() (string, error) {
	return "", fmt.Errorf("lifetime network totals support Linux and macOS only")
}
