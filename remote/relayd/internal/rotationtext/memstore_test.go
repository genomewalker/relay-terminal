package rotationtext

import "errors"

// memoryStore is an in-memory Store with BEGIN IMMEDIATE rollback semantics,
// used to test the journal logic independently of its on-disk format.
type memoryStore struct {
	settingsID, settingsValue string
	hasSettings               bool
	changes                   map[string]string
	rows                      []Operation
	snapshot                  *memoryStore
	closed                    bool
	failNext                  error
}

func newMemoryStore() *memoryStore { return &memoryStore{changes: map[string]string{}} }

func (m *memoryStore) copyState() *memoryStore {
	changes := map[string]string{}
	for key, value := range m.changes {
		changes[key] = value
	}
	return &memoryStore{settingsID: m.settingsID, settingsValue: m.settingsValue, hasSettings: m.hasSettings,
		changes: changes, rows: append([]Operation(nil), m.rows...)}
}

func (m *memoryStore) Begin() error {
	if m.snapshot != nil {
		return errors.New("cannot start a transaction within a transaction")
	}
	m.snapshot = m.copyState()
	return nil
}

func (m *memoryStore) Commit() error {
	if err := m.failNext; err != nil {
		m.failNext = nil
		return err
	}
	m.snapshot = nil
	return nil
}

func (m *memoryStore) Rollback() error {
	if m.snapshot == nil {
		return errors.New("no transaction is active")
	}
	saved := m.snapshot
	m.settingsID, m.settingsValue, m.hasSettings = saved.settingsID, saved.settingsValue, saved.hasSettings
	m.changes, m.rows, m.snapshot = saved.changes, saved.rows, nil
	return nil
}

func (m *memoryStore) InTransaction() bool { return m.snapshot != nil }

func (m *memoryStore) InitSettings(value string) error {
	if !m.hasSettings {
		m.settingsID, m.settingsValue, m.hasSettings = "", value, true
	}
	return nil
}

func (m *memoryStore) Settings() (string, string, bool, error) {
	return m.settingsID, m.settingsValue, m.hasSettings, nil
}

func (m *memoryStore) UpdateSettings(id, value string) error {
	if m.hasSettings {
		m.settingsID, m.settingsValue = id, value
	}
	return nil
}

func (m *memoryStore) ConfigurationChange(id string) (string, bool, error) {
	value, ok := m.changes[id]
	return value, ok, nil
}

func (m *memoryStore) InsertConfigurationChange(id, value string) error {
	if _, ok := m.changes[id]; ok {
		return errors.New("UNIQUE constraint failed")
	}
	m.changes[id] = value
	return nil
}

func (m *memoryStore) Operations() ([]Operation, error) {
	return append([]Operation(nil), m.rows...), nil
}

func (m *memoryStore) InsertOperation(row Operation) error {
	for _, existing := range m.rows {
		if existing.ID == row.ID || existing.Fingerprint == row.Fingerprint {
			return errors.New("UNIQUE constraint failed")
		}
	}
	m.rows = append(m.rows, row)
	return nil
}

func (m *memoryStore) FinishOperation(id, state string, charged int64, result string) error {
	for i := range m.rows {
		if m.rows[i].ID == id && m.rows[i].State == "pending" {
			m.rows[i].State, m.rows[i].Charged = state, charged
			m.rows[i].Result = &result
		}
	}
	return nil
}

func (m *memoryStore) AbandonOperation(id string) error {
	for i := range m.rows {
		if m.rows[i].ID == id && (m.rows[i].State == "pending" || m.rows[i].State == "uncertain") {
			m.rows[i].State = "abandoned"
		}
	}
	return nil
}

func (m *memoryStore) Close() error { m.closed = true; return nil }
