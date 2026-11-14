//go:build linux || darwin

package monitoring

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/komari-monitor/komari-agent/monitoring/nettotal"
)

func TestPersistentNetworkUsesRawCountersForSpeedAndRetainsTotalsOnError(t *testing.T) {
	// Exercise the report path with native counters and seeded lifetime history.
	if os.PathSeparator != '/' {
		t.Skip("Unix fixture")
	}
	bootID, err := nettotal.BootID()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "state")
	store, err := nettotal.Open(path, bootID)
	if err != nil {
		t.Fatal(err)
	}
	old := persistentNetwork.store
	oldMode, oldInclude, oldExclude := flags.NetworkMode, flags.IncludeNics, flags.ExcludeNics
	persistentNetwork.store = store
	flags.NetworkMode = "lifetime"
	flags.IncludeNics, flags.ExcludeNics = "", ""
	defer func() {
		persistentNetwork.store = old
		flags.NetworkMode = oldMode
		flags.IncludeNics = oldInclude
		flags.ExcludeNics = oldExclude
		store.Close()
	}()
	// Seed history much larger than any live NIC; it must not affect speed.
	if _, _, err = store.Update([]nettotal.Counter{{Name: "historical-nic", Tx: 1 << 40, Rx: 1 << 41}}); err != nil {
		t.Fatal(err)
	}
	up, down, _, _, err := NetworkSpeed()
	if err != nil {
		t.Fatal(err)
	}
	if up < 1<<40 || down < 1<<41 {
		t.Fatalf("history lost: %d,%d", up, down)
	}
	// Force a failed rename. The report must preserve the last committed totals.
	if err = os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err = os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	up2, down2, _, _, err := NetworkSpeed()
	if err == nil || up2 != up || down2 != down {
		t.Fatalf("failed checkpoint reset totals: %d,%d,%v", up2, down2, err)
	}
}
