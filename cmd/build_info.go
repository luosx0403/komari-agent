package cmd

import (
	"encoding/json"
	"runtime"

	"github.com/komari-monitor/komari-agent/update"
	"github.com/spf13/cobra"
)

func init() {
	RootCmd.AddCommand(&cobra.Command{
		Use:   "build-info",
		Short: "Print build and lifetime traffic capabilities without starting the agent",
		RunE: func(cmd *cobra.Command, args []string) error {
			return json.NewEncoder(cmd.OutOrStdout()).Encode(map[string]interface{}{
				"version":                       update.CurrentVersion,
				"update_repo":                   update.Repo,
				"os":                            runtime.GOOS,
				"arch":                          runtime.GOARCH,
				"lifetime_network":              runtime.GOOS == "linux" || runtime.GOOS == "darwin",
				"network_state_version":         1,
				"network_sync_on_report_option": true,
			})
		},
	})
}
