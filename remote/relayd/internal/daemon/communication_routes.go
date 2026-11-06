package daemon

import (
	"errors"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const communicationMaxRoutes = 128

// A route pins a peer node to a reviewed transport binding. The binding is an
// opaque identifier, never a shell command, address, socket or credential.
// Registration is not connectivity verification or authority to deliver.
type communicationRoute struct {
	Version            int       `json:"version"`
	ID                 string    `json:"id"`
	NodeID             string    `json:"node_id"`
	PeerNodeID         string    `json:"peer_node_id"`
	TransportBindingID string    `json:"transport_binding_id"`
	Revision           uint64    `json:"revision"`
	Retired            bool      `json:"retired"`
	CreatedAt          time.Time `json:"created_at"`
	UpdatedAt          time.Time `json:"updated_at"`
}

func canonicalRouteToken(value string) bool {
	return value == strings.ToLower(value) && validSessionID.MatchString(value)
}

func validCommunicationRoute(route communicationRoute, nodeID string) bool {
	return route.Version == 1 && route.NodeID == nodeID && nodeID != "" &&
		canonicalRouteToken(route.ID) && canonicalRouteToken(route.PeerNodeID) &&
		route.PeerNodeID != nodeID && canonicalRouteToken(route.TransportBindingID) &&
		route.Revision != 0 && !route.CreatedAt.IsZero() && !route.UpdatedAt.Before(route.CreatedAt)
}

func communicationRouteResult(route communicationRoute) map[string]any {
	return map[string]any{"route": route, "authority": "relayd", "desktop_required": false,
		"connectivity": "unverified", "delivery_enabled": false}
}

// The communication flock and owner authorization precede this reducer.
func communicationRouteOperation(root, nodeID string, r CommunicationRequest) (map[string]any, error) {
	if nodeID == "" {
		return nil, errors.New("daemon node identity unavailable")
	}
	if r.ClientToken != "" || r.ActorPaneID != "" {
		return nil, errors.New("owner administration required")
	}
	if strings.HasPrefix(r.Operation, "route_claude_session_") {
		return communicationClaudeSessionOperation(root, r, time.Now)
	}
	if r.Operation == "route_scope_set" {
		return communicationScopeSet(root, nodeID, r)
	}
	if strings.HasPrefix(r.Operation, "route_link_") {
		return communicationRemoteLinkOperation(root, nodeID, r)
	}
	if r.Operation == "route_identity_create" || r.Operation == "route_identity_get" || r.Operation == "route_identity_rotate" || r.Operation == "route_binding_set" || r.Operation == "route_binding_get" || r.Operation == "route_binding_transport_set" {
		return communicationPeerConfiguration(root, nodeID, r)
	}
	if r.Operation == "route_list" {
		routes, err := communicationReadRoutes(root, nodeID)
		if err != nil {
			return nil, err
		}
		return map[string]any{"routes": routes, "authority": "relayd", "desktop_required": false,
			"connectivity": "unverified", "delivery_enabled": false}, nil
	}
	id := strings.ToLower(r.RouteID)
	if !canonicalRouteToken(id) {
		return nil, errors.New("valid route identity required")
	}
	path := filepath.Join(root, "route-"+id+".json")
	var previous communicationRoute
	err := communicationRead(path, &previous)
	exists := err == nil
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if exists && (!validCommunicationRoute(previous, nodeID) || previous.ID != id) {
		return nil, errors.New("invalid stored communication route")
	}
	if r.Operation == "route_get" {
		if !exists {
			return nil, errors.New("communication route not found")
		}
		return communicationRouteResult(previous), nil
	}
	if r.Operation != "route_set" && r.Operation != "route_retire" {
		return nil, errors.New("unsupported route operation")
	}
	if !exists && r.Operation == "route_retire" {
		return nil, errors.New("communication route not found")
	}
	if r.ExpectedRouteRevision != previous.Revision || previous.Revision == math.MaxUint64 {
		return nil, errors.New("communication route revision conflict")
	}
	route := previous
	if r.Operation == "route_set" {
		peer, binding := strings.ToLower(r.PeerNodeID), strings.ToLower(r.TransportBindingID)
		if !canonicalRouteToken(peer) || peer == nodeID || !canonicalRouteToken(binding) {
			return nil, errors.New("valid remote node and transport binding required")
		}
		// A route identity must not silently become a different peer/binding.
		// Retire it and create a new identity when reviewing a different target.
		if exists && (previous.PeerNodeID != peer || previous.TransportBindingID != binding) {
			return nil, errors.New("route target is immutable; create a new route identity")
		}
		routes, err := communicationReadRoutes(root, nodeID)
		if err != nil {
			return nil, err
		}
		if !exists && len(routes) >= communicationMaxRoutes {
			return nil, errors.New("communication route limit reached")
		}
		for _, other := range routes {
			if other.ID != id && !other.Retired && other.PeerNodeID == peer {
				return nil, errors.New("peer already has an active communication route")
			}
		}
		route = communicationRoute{Version: 1, ID: id, NodeID: nodeID, PeerNodeID: peer,
			TransportBindingID: binding, CreatedAt: previous.CreatedAt}
	}
	now := time.Now().UTC()
	if !exists {
		route.CreatedAt = now
	}
	route.UpdatedAt, route.Revision = now, previous.Revision+1
	route.Retired = r.Operation == "route_retire"
	if err := communicationAtomic(path, route); err != nil {
		return nil, err
	}
	kind := "communication_route_updated"
	if route.Retired {
		kind = "communication_route_retired"
	}
	if err := communicationEvent(root, nodeID, kind, []map[string]string{{"route_id": id,
		"peer_node_id": route.PeerNodeID, "transport_binding_id": route.TransportBindingID}}); err != nil {
		return nil, errors.New("route saved but event append failed; read current revision before recovery")
	}
	return communicationRouteResult(route), nil
}

func communicationReadRoutes(root, nodeID string) ([]communicationRoute, error) {
	paths, err := filepath.Glob(filepath.Join(root, "route-*.json"))
	if err != nil {
		return nil, err
	}
	if len(paths) > communicationMaxRoutes {
		return nil, errors.New("communication route catalogue exceeds limit")
	}
	routes := make([]communicationRoute, 0, len(paths))
	for _, path := range paths {
		var route communicationRoute
		if err := communicationRead(path, &route); err != nil {
			return nil, err
		}
		if !validCommunicationRoute(route, nodeID) || filepath.Base(path) != "route-"+route.ID+".json" {
			return nil, errors.New("invalid stored communication route")
		}
		routes = append(routes, route)
	}
	return routes, nil
}
