package update

import "testing"

func TestSetRepository(t *testing.T) {
	old := Repo
	defer func() { Repo = old }()
	for _, repo := range []string{"luosx0403/komari-agent", "komari-monitor/komari-agent"} {
		if err := SetRepository(repo); err != nil || Repo != repo {
			t.Fatalf("set %q: %v", repo, err)
		}
	}
	for _, repo := range []string{"missing-owner", "x/y/z", "x/y?token=z", "x/y\n"} {
		if err := SetRepository(repo); err == nil {
			t.Fatalf("accepted %q", repo)
		}
	}
}
