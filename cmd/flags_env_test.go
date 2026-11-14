package cmd

import "testing"

func TestEnvironmentBooleanFalseOverridesTrueDefault(t *testing.T) {
	old := *flags
	defer func() { *flags = old }()
	for _, value := range []string{"false", "0", "FALSE"} {
		t.Setenv("AGENT_NETWORK_SYNC_ON_REPORT", value)
		flags.NetworkSyncOnReport = true
		loadFromEnv()
		if flags.NetworkSyncOnReport {
			t.Fatalf("%q did not override true default", value)
		}
	}
	for _, value := range []string{"true", "1", "TRUE"} {
		t.Setenv("AGENT_NETWORK_SYNC_ON_REPORT", value)
		flags.NetworkSyncOnReport = false
		loadFromEnv()
		if !flags.NetworkSyncOnReport {
			t.Fatalf("%q did not enable syncing", value)
		}
	}
}
