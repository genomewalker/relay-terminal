package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"syscall"
)

type NativeGroupMember struct {
	Host         string `json:"host"`
	Session      string `json:"session"`
	Name         string `json:"name"`
	PID          int    `json:"pid"`
	ProcessStart string `json:"processStart"`
}

type NativeGroupStatus struct {
	ID            string              `json:"id"`
	Topology      string              `json:"topology"`
	CoordinatorID string              `json:"coordinatorID,omitempty"`
	Participants  []NativeGroupMember `json:"participants"`
	Current       bool                `json:"current"`
}

var nativeGroupFile = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.json$`)

// Read only bounded, private group receipts. A socket write is an introduction,
// not proof of a durable transport or of provider processing.
func readNativeGroupStatuses(home string, peers []NetworkPeer) []NativeGroupStatus {
	root := filepath.Join(home, ".local", "state", "relay", "native-groups")
	rootInfo, err := os.Lstat(root)
	if err != nil || !rootInfo.IsDir() || rootInfo.Mode().Perm()&0022 != 0 {
		return nil
	}
	if stat, ok := rootInfo.Sys().(*syscall.Stat_t); !ok || stat.Uid != uint32(os.Getuid()) {
		return nil
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	result := []NativeGroupStatus{}
	for _, entry := range entries {
		if len(result) >= 64 {
			break
		}
		if !nativeGroupFile.MatchString(entry.Name()) || !entry.Type().IsRegular() {
			continue
		}
		path := filepath.Join(root, entry.Name())
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0022 != 0 || info.Size() > 32768 {
			continue
		}
		if stat, ok := info.Sys().(*syscall.Stat_t); !ok || stat.Uid != uint32(os.Getuid()) {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil || len(data) > 32768 {
			continue
		}
		var receipt struct {
			Group         string              `json:"group"`
			State         string              `json:"state"`
			Topology      string              `json:"topology"`
			CoordinatorID string              `json:"coordinatorID"`
			Participants  []NativeGroupMember `json:"participants"`
			Introductions []struct {
				Receipt string `json:"receipt"`
			} `json:"introductions"`
		}
		if json.Unmarshal(data, &receipt) != nil || receipt.State != "introductions_attempted" ||
			len(receipt.Participants) < 2 || len(receipt.Participants) > 8 ||
			len(receipt.Introductions) != len(receipt.Participants) ||
			(receipt.Topology != "everyone" && receipt.Topology != "coordinator") {
			continue
		}
		if !nativeGroupFile.MatchString(receipt.Group+".json") ||
			!equalFoldUUID(receipt.Group+".json", entry.Name()) {
			continue
		}
		complete := true
		for _, intro := range receipt.Introductions {
			if intro.Receipt != "written_to_socket" {
				complete = false
			}
		}
		if !complete {
			continue
		}
		group := NativeGroupStatus{ID: receipt.Group, Topology: receipt.Topology,
			CoordinatorID: receipt.CoordinatorID, Participants: receipt.Participants, Current: true}
		for _, member := range group.Participants {
			found := false
			for _, peer := range peers {
				if member.Host != group.Participants[0].Host {
					break
				}
				if peer.PID == member.PID && peer.Start == member.ProcessStart &&
					peer.Session == member.Session && peer.Name == member.Name {
					found = true
					break
				}
			}
			if !found {
				group.Current = false
				break
			}
		}
		result = append(result, group)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].ID < result[j].ID })
	return result
}

func equalFoldUUID(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		x, y := a[i], b[i]
		if x >= 'A' && x <= 'F' {
			x += 'a' - 'A'
		}
		if y >= 'A' && y <= 'F' {
			y += 'a' - 'A'
		}
		if x != y {
			return false
		}
	}
	return true
}
