//go:build linux || darwin

package monitoring

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

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
	oldSync := flags.NetworkSyncOnReport
	flags.NetworkSyncOnReport = true
	defer func() { flags.NetworkSyncOnReport = oldSync }()
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

func TestPersistentNetworkCheckpointsWithoutControllerAndRestarts(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux procfs fixture; macOS store/collector tests run natively")
	}
	proc := t.TempDir()
	if err := os.Mkdir(filepath.Join(proc, "net"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOST_PROC", proc)
	writeCounters := func(tx, rx uint64) {
		t.Helper()
		file := filepath.Join(proc, "net/dev")
		data := fmt.Sprintf("Inter-| Receive | Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\n eth0: %d 1 0 0 0 0 0 0 %d 1 0 0 0 0 0 0\n", rx, tx)
		if err := os.WriteFile(file+".tmp", []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Rename(file+".tmp", file); err != nil {
			t.Fatal(err)
		}
	}
	oldMode, oldInclude, oldExclude := flags.NetworkMode, flags.IncludeNics, flags.ExcludeNics
	flags.NetworkMode, flags.IncludeNics, flags.ExcludeNics = "lifetime", "eth0", ""
	path := filepath.Join(t.TempDir(), "state")
	defer func() {
		if persistentNetwork.store != nil {
			_ = StopPersistentNetwork()
			_ = persistentNetwork.store.Close()
			persistentNetwork.store = nil
		}
		flags.NetworkMode, flags.IncludeNics, flags.ExcludeNics = oldMode, oldInclude, oldExclude
	}()
	writeCounters(100, 200)
	if err := StartPersistentNetwork(path, 0.1); err != nil {
		t.Fatal(err)
	}
	writeCounters(130, 250)
	deadline := time.Now().Add(3 * time.Second)
	for {
		b, err := os.ReadFile(path)
		var state struct {
			TotalUp   uint64 `json:"total_up"`
			TotalDown uint64 `json:"total_down"`
		}
		if err == nil {
			_ = json.Unmarshal(b, &state)
		}
		if state.TotalUp == 130 && state.TotalDown == 250 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("offline checkpoint did not advance: %s, %v", b, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err := StopPersistentNetwork(); err != nil {
		t.Fatal(err)
	}
	_ = persistentNetwork.store.Close()
	persistentNetwork.store = nil
	writeCounters(140, 260)
	if err := StartPersistentNetwork(path, 0.1); err != nil {
		t.Fatal(err)
	}
	up, down, _, _, err := NetworkSpeed()
	if err != nil || up != 140 || down != 260 {
		t.Fatalf("process restart recounted traffic: %d,%d,%v", up, down, err)
	}
}
