package programstatus

// TrackerState is the durable part of a Tracker: the current records and the
// revision counter. A pane worker that re-executes itself carries it across
// exec so attention state and revision cursors stay continuous. Parser state
// is not carried; the owner only exports between whole PTY reads.
type TrackerState struct {
	Records  []Record `json:"records,omitempty"`
	Revision uint64   `json:"revision"`
}

// Export returns detached records exactly as stored, unlike Snapshot, which
// fills presentation defaults.
func (t *Tracker) Export() TrackerState {
	state := TrackerState{Revision: t.revision, Records: make([]Record, 0, len(t.records))}
	for _, record := range t.records {
		if record.Progress != nil {
			p := *record.Progress
			record.Progress = &p
		}
		state.Records = append(state.Records, record)
	}
	return state
}

// Restore replaces the tracker with an exported state. Records beyond the
// tracker's bound are dropped rather than trusted.
func (t *Tracker) Restore(state TrackerState) {
	*t = Tracker{revision: state.Revision}
	for _, record := range state.Records {
		if len(t.records) >= MaxRecords {
			break
		}
		if t.records == nil {
			t.records = map[string]Record{}
		}
		if record.Revision > t.revision {
			t.revision = record.Revision
		}
		t.records[record.ID] = record
	}
}
