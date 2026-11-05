package rotationtext

// Runtime additions to the frozen imported tool schemas. Both validation and
// the actual API request use this same schema.
func currentAssistantTools() []any {
	tools := parseJSON(assistantToolsJSON).([]any)
	for _, raw := range tools {
		tool := raw.(obj)
		if tool["name"] != "list_panes" {
			continue
		}
		tool["description"] = "Read panes across the whole workspace, including account labels. Query matches pane, tab, host, provider or account. Follow next_offset until null to finish an inventory; each page is bounded."
		tool["input_schema"].(obj)["properties"].(obj)["offset"] = obj{
			"type": "integer", "minimum": int64(0), "maximum": int64(1000000),
			"description": "Use next_offset from the preceding page with the same query.",
		}
	}
	return tools
}
