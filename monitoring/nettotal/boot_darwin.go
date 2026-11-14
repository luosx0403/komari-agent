package nettotal

import (
	"fmt"
	"golang.org/x/sys/unix"
)

func BootID() (string, error) {
	// kern.boottime is stable for this boot; do not derive it from wall clock minus uptime.
	tv, err := unix.SysctlTimeval("kern.boottime")
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("darwin:%d:%d", tv.Sec, tv.Usec), nil
}
