package daemon

import "encoding/json"

// maxFocusRoutes bounds a Focus frame: one pane has an interactive route and
// at most a few event-only routes.
const maxFocusRoutes = 4

// ParseFocusRoutes reads a Focus payload {"routes":[...]}. An empty list is
// valid and clears focus. Any route that is not a session ID rejects the frame.
func ParseFocusRoutes(payload []byte) ([]string, bool) {
	var focus struct {
		Routes []string `json:"routes"`
	}
	if json.Unmarshal(payload, &focus) != nil || len(focus.Routes) > maxFocusRoutes {
		return nil, false
	}
	for _, route := range focus.Routes {
		if !validSessionID.MatchString(route) {
			return nil, false
		}
	}
	return focus.Routes, true
}
