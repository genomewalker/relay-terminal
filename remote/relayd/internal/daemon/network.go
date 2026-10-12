package daemon

import (
	"os"

	"github.com/relay-terminal/relayd/internal/peernet"
)

type NetworkPeer struct {
	peernet.DiscoveredPeer
	PaneID        string `json:"paneID"`
	ParentSession string `json:"parentSession,omitempty"`
}
type NetworkDiscovery struct {
	Peers     []NetworkPeer            `json:"peers"`
	Truncated bool                     `json:"truncated"`
	Links     []peernet.DiscoveredLink `json:"links"`
	Groups    []NativeGroupStatus      `json:"groups"`
	Teams     []peernet.ClaudeTeam     `json:"teams"`
}

// NetworkSnapshot only exports peers descended from a validated Relay worker.
// It never opens an inbox, registers a proxy, or changes a running worker.
func (s *Server) NetworkSnapshot() (NetworkDiscovery, error) {
	result := NetworkDiscovery{Peers: []NetworkPeer{}}
	catalog, err := s.CatalogSnapshot()
	if err != nil {
		return result, err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return result, err
	}
	discovery, err := peernet.Discover(home)
	if err != nil {
		return result, err
	}
	result.Truncated = discovery.Truncated
	result.Links = discovery.Links
	for _, peer := range discovery.Peers {
		chain, err := networkAncestors(peer.PID, peer.Start)
		if err != nil {
			continue
		}
		for _, pane := range catalog.Panes {
			if !pane.Recoverable || pane.State != "running" {
				continue
			}
			shell, belongs := networkPeerPaneOwnership(chain, pane)
			if !belongs {
				continue
			}
			// Revalidate after walking the process tree so a dead/reused worker cannot own a peer.
			manifest, e := loadManifest(s.manifestPath(pane.PaneID))
			if e != nil || validateWorkerIdentity(manifest) != nil {
				continue
			}
			row := NetworkPeer{DiscoveredPeer: peer, PaneID: pane.PaneID}
			for index := 1; index < shell; index++ {
				ancestor := chain[index]
				for _, candidate := range discovery.Peers {
					if candidate.PID == ancestor {
						stamp, e := processStartIdentity(ancestor)
						if e == nil && stamp == candidate.Start {
							row.ParentSession = candidate.Session
						}
					}
				}
				if row.ParentSession != "" {
					break
				}
			}
			result.Peers = append(result.Peers, row)
			break
		}
	}
	result.Groups = readNativeGroupStatuses(home, result.Peers)
	result.Teams = paneBoundTeams(result.Peers, discovery.Teams)
	return result, nil
}

func paneBoundTeams(peers []NetworkPeer, teams []peernet.ClaudeTeam) []peernet.ClaudeTeam {
	// Team configuration is descriptive metadata, not a live agent roster or
	// communication edge. Export it only for a uniquely pane-bound lead.
	paneLeads := map[string]int{}
	for _, peer := range peers {
		paneLeads[peer.Session]++
	}
	result := []peernet.ClaudeTeam{}
	for _, team := range teams {
		if paneLeads[team.LeadSession] == 1 {
			result = append(result, team)
		}
	}
	return result
}

// networkPeerPaneOwnership accepts a provider which exec'd the pane shell as
// well as its descendants. The verified kernel chain includes the peer itself
// at index zero; the worker must remain a strict ancestor in either case.
func networkPeerPaneOwnership(chain []int, pane CatalogPane) (int, bool) {
	if pane.ShellPID <= 1 || pane.WorkerPID <= 1 || pane.ShellPID == pane.WorkerPID {
		return -1, false
	}
	shell, worker := -1, -1
	for index, pid := range chain {
		if pid == pane.ShellPID {
			shell = index
		}
		if pid == pane.WorkerPID {
			worker = index
		}
	}
	return shell, shell >= 0 && worker > shell
}
