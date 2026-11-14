// Package nettotal persists lifetime network totals independently of monthly rotation.
package nettotal

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

type Counter struct {
	Name string
	Tx   uint64
	Rx   uint64
}

type reading struct {
	Tx uint64 `json:"tx"`
	Rx uint64 `json:"rx"`
}

type state struct {
	Version   int                `json:"version"`
	BootID    string             `json:"boot_id"`
	TotalUp   uint64             `json:"total_up"`
	TotalDown uint64             `json:"total_down"`
	Counters  map[string]reading `json:"counters"`
}

type Store struct {
	mu      sync.Mutex
	path    string
	bootID  string
	current state
	lock    *os.File // Retain the exclusive lock for the process lifetime.
}

func Open(path, bootID string) (*Store, error) {
	if !filepath.IsAbs(path) || strings.TrimSpace(bootID) == "" {
		return nil, fmt.Errorf("absolute state path and nonempty boot ID required")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	lock, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = lockFile(lock); err != nil {
		lock.Close()
		return nil, fmt.Errorf("network state already in use: %w", err)
	}
	s := &Store{path: path, bootID: bootID, lock: lock, current: state{Version: 1, BootID: bootID, Counters: map[string]reading{}}}
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err == nil {
		var fields map[string]json.RawMessage
		err = json.Unmarshal(b, &fields)
		if err == nil {
			for _, name := range []string{"version", "boot_id", "total_up", "total_down", "counters"} {
				if raw, ok := fields[name]; !ok || string(raw) == "null" {
					err = fmt.Errorf("missing network state field %s", name)
					break
				}
			}
		}
		var loaded state
		if err == nil {
			err = json.Unmarshal(b, &loaded)
		}
		s.current = loaded
		if err == nil && (s.current.Version != 1 || s.current.BootID == "" || s.current.Counters == nil || s.current.TotalUp > math.MaxInt64 || s.current.TotalDown > math.MaxInt64) {
			err = fmt.Errorf("invalid network state")
		}
	}
	if err != nil {
		lock.Close()
		return nil, fmt.Errorf("refusing to reset unreadable network state %s: %w", path, err)
	}
	return s, nil
}

// Update commits totals before returning them for upload. A failed write retains
// the previous totals and baseline so the next successful sample catches up.
func (s *Store) Update(counters []Counter) (uint64, uint64, error) {
	return s.update(counters, true)
}

// UpdateMemory is opt-in for flash-backed systems. Call Update periodically and
// on shutdown to checkpoint; a crash can lose uncheckpointed increments.
func (s *Store) UpdateMemory(counters []Counter) (uint64, uint64, error) {
	return s.update(counters, false)
}

func (s *Store) update(counters []Counter, persist bool) (uint64, uint64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := s.current
	next.Counters = make(map[string]reading)
	if next.BootID == s.bootID {
		for name, value := range s.current.Counters {
			next.Counters[name] = value
		}
	}
	next.BootID = s.bootID
	for _, c := range counters {
		previous, known := next.Counters[c.Name]
		up, down := c.Tx, c.Rx
		if known {
			// A counter decrease indicates a recreated/reset interface.
			if c.Tx >= previous.Tx {
				up = c.Tx - previous.Tx
			}
			if c.Rx >= previous.Rx {
				down = c.Rx - previous.Rx
			}
		}
		if up > uint64(math.MaxInt64)-next.TotalUp || down > uint64(math.MaxInt64)-next.TotalDown {
			return s.current.TotalUp, s.current.TotalDown, fmt.Errorf("network totals exceed protocol int64 limit")
		}
		next.TotalUp += up
		next.TotalDown += down
		next.Counters[c.Name] = reading{Tx: c.Tx, Rx: c.Rx}
	}
	if !persist {
		s.current = next
		return next.TotalUp, next.TotalDown, nil
	}
	committed, err := s.save(next)
	if committed {
		s.current = next
	}
	return s.current.TotalUp, s.current.TotalDown, err
}

func (s *Store) save(next state) (bool, error) {
	b, err := json.Marshal(next)
	if err != nil {
		return false, err
	}
	f, err := os.CreateTemp(filepath.Dir(s.path), ".network-total-*")
	if err != nil {
		return false, err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(b); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return false, err
	}
	if closeErr != nil {
		return false, closeErr
	}
	if err = os.Rename(f.Name(), s.path); err != nil {
		return false, err
	}
	// After rename, keep the committed baseline even if directory fsync fails.
	d, err := os.Open(filepath.Dir(s.path))
	if err != nil {
		return true, err
	}
	defer d.Close()
	return true, d.Sync()
}

func (s *Store) Totals() (uint64, uint64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.current.TotalUp, s.current.TotalDown
}

func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lock.Close()
}
