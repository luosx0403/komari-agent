//go:build linux || darwin

package nettotal

import (
	"os"
	"path/filepath"
	"testing"
)

func mustOpen(t *testing.T, path, boot string) *Store {
	t.Helper()
	s, err := Open(path, boot)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func checkUpdate(t *testing.T, s *Store, counters []Counter, up, down uint64) {
	t.Helper()
	u, d, err := s.Update(counters)
	if err != nil || u != up || d != down {
		t.Fatalf("got (%d,%d,%v), want (%d,%d,nil)", u, d, err, up, down)
	}
}

func TestLifetimeSurvivesAgentAndHostRestarts(t *testing.T) {
	path := filepath.Join(t.TempDir(), "totals.json")
	s := mustOpen(t, path, "boot-a")
	checkUpdate(t, s, []Counter{{"eth0", 100, 200}, {"en1", 40, 60}}, 140, 260)
	checkUpdate(t, s, []Counter{{"eth0", 125, 250}, {"en1", 45, 70}}, 170, 320)
	s.Close()
	s = mustOpen(t, path, "boot-a")
	// Same-boot process restart must add only unseen traffic, not the whole NIC counter.
	checkUpdate(t, s, []Counter{{"eth0", 130, 260}, {"en1", 45, 70}}, 175, 330)
	s.Close()
	s = mustOpen(t, path, "boot-b")
	// New boot adds new counters even if they already exceed last boot's counters.
	checkUpdate(t, s, []Counter{{"eth0", 500, 600}}, 675, 930)
	// NIC missing at startup can appear later without reusing its old baseline.
	checkUpdate(t, s, []Counter{{"eth0", 510, 615}, {"en1", 5, 8}}, 690, 953)
	s.Close()
	s = mustOpen(t, path, "boot-b")
	defer s.Close()
	checkUpdate(t, s, []Counter{{"eth0", 510, 615}, {"en1", 5, 8}}, 690, 953)
}

func TestInterfaceResetAndTemporaryDisappearance(t *testing.T) {
	s := mustOpen(t, filepath.Join(t.TempDir(), "state"), "boot")
	defer s.Close()
	checkUpdate(t, s, []Counter{{"eth0", 100, 200}}, 100, 200)
	checkUpdate(t, s, nil, 100, 200)
	checkUpdate(t, s, []Counter{{"eth0", 110, 210}}, 110, 210)
	checkUpdate(t, s, []Counter{{"eth0", 3, 4}}, 113, 214)
	checkUpdate(t, s, []Counter{{"eth0", 8, 9}}, 118, 219)
}

func TestRefusesCorruptionAndConcurrentWriter(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state")
	s := mustOpen(t, path, "boot")
	if other, err := Open(path, "boot"); err == nil {
		other.Close()
		t.Fatal("second writer accepted")
	}
	s.Close()
	for _, data := range []string{"", "{broken", "{}", `{"version":2,"boot_id":"x","counters":{}}`} {
		if err := os.WriteFile(path, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
		if other, err := Open(path, "boot"); err == nil {
			other.Close()
			t.Fatalf("accepted corrupt state %q", data)
		}
	}
}

func TestFailedWriteRetainsTotalsAndBaseline(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state")
	s := mustOpen(t, path, "boot")
	defer s.Close()
	checkUpdate(t, s, []Counter{{"eth0", 100, 200}}, 100, 200)
	// Make rename fail deterministically, including when tests run as root.
	os.Remove(path)
	os.Mkdir(path, 0700)
	u, d, err := s.Update([]Counter{{"eth0", 120, 230}})
	if err == nil || u != 100 || d != 200 {
		t.Fatalf("failed save changed totals: %d,%d,%v", u, d, err)
	}
	os.Remove(path)
	checkUpdate(t, s, []Counter{{"eth0", 150, 260}}, 150, 260)
}

func TestBootIDStable(t *testing.T) {
	a, err := BootID()
	if err != nil || a == "" {
		t.Fatalf("boot ID: %q, %v", a, err)
	}
	b, err := BootID()
	if err != nil || a != b {
		t.Fatalf("unstable boot ID: %q, %q, %v", a, b, err)
	}
}
