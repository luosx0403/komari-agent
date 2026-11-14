package monitoring

import (
	"context"
	"fmt"
	"log"
	"path/filepath"
	"sync"
	"time"

	"github.com/komari-monitor/komari-agent/monitoring/nettotal"
	"github.com/shirou/gopsutil/v4/net"
)

var persistentNetwork struct {
	sync.Mutex
	store  *nettotal.Store
	cancel context.CancelFunc
	done   chan struct{}
}

// StartPersistentNetwork checkpoints even while the controller is unreachable.
func StartPersistentNetwork(path string, interval float64) error {
	if path == "" {
		var err error
		path, err = filepath.Abs("network-total.json")
		if err != nil {
			return err
		}
	}
	bootID, err := nettotal.BootID()
	if err != nil {
		return fmt.Errorf("read boot ID: %w", err)
	}
	store, err := nettotal.Open(path, bootID)
	if err != nil {
		return err
	}
	persistentNetwork.store = store
	if _, _, _, _, err := samplePersistentNetwork(true); err != nil {
		_ = store.Close()
		persistentNetwork.store = nil
		return fmt.Errorf("initialize lifetime network state: %w", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	persistentNetwork.cancel = cancel
	persistentNetwork.done = make(chan struct{})
	go func() {
		defer close(persistentNetwork.done)
		ticker := time.NewTicker(time.Duration(interval * float64(time.Second)))
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if _, _, _, _, err := samplePersistentNetwork(true); err != nil {
					log.Printf("Lifetime network checkpoint failed: %v", err)
				}
			}
		}
	}()
	log.Printf("Lifetime network totals enabled: %s (no monthly reset)", path)
	return nil
}

// Serialize both reading counters and committing them; a stale concurrent sample
// must never be mistaken for a counter reset.
func samplePersistentNetwork(persist bool) (rawUp, rawDown, totalUp, totalDown uint64, err error) {
	persistentNetwork.Lock()
	defer persistentNetwork.Unlock()
	store := persistentNetwork.store
	if store == nil {
		return 0, 0, 0, 0, fmt.Errorf("lifetime network store is not initialized")
	}
	totalUp, totalDown = store.Totals()
	ios, err := net.IOCounters(true)
	if err != nil {
		return 0, 0, totalUp, totalDown, err
	}
	if len(ios) == 0 {
		return 0, 0, totalUp, totalDown, fmt.Errorf("no network interfaces found")
	}
	include, exclude := parseNics(flags.IncludeNics), parseNics(flags.ExcludeNics)
	counters := []nettotal.Counter{}
	for _, io := range ios {
		if shouldInclude(io.Name, include, exclude) {
			rawUp += io.BytesSent
			rawDown += io.BytesRecv
			counters = append(counters, nettotal.Counter{Name: io.Name, Tx: io.BytesSent, Rx: io.BytesRecv})
		}
	}
	if persist {
		totalUp, totalDown, err = store.Update(counters)
	} else {
		totalUp, totalDown, err = store.UpdateMemory(counters)
	}
	return rawUp, rawDown, totalUp, totalDown, err
}

func persistentNetworkSpeed() (totalUp, totalDown, upSpeed, downSpeed uint64, err error) {
	rawUp, rawDown, totalUp, totalDown, err := samplePersistentNetwork(flags.NetworkSyncOnReport)
	if err != nil {
		return totalUp, totalDown, 0, 0, err
	}
	upSpeed, downSpeed = updateNetworkSpeedSample(rawUp, rawDown, time.Now())
	return totalUp, totalDown, upSpeed, downSpeed, nil
}

func StopPersistentNetwork() error {
	if persistentNetwork.store == nil {
		return nil
	}
	persistentNetwork.cancel()
	<-persistentNetwork.done
	_, _, _, _, err := samplePersistentNetwork(true)
	// Keep the process lock until os.Exit, including while a report finishes.
	return err
}
