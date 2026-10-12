package daemon

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

// Worst-case manifests also appear as map keys and in per-file receipts. This
// bounds the entire journal while accommodating all 1024 maximum-length paths.
const folderJournalLimit = 8 << 20

// Private journal only. RPC responses must use folderGroupStatus, never this
// record, which contains the reservation ownership nonce and staging metadata.
type folderGroupRecord struct {
	Format           int                          `json:"format"`
	ID               string                       `json:"id"`
	Pane             string                       `json:"pane"`
	SourceVersion    string                       `json:"source_version"`
	Fingerprint      string                       `json:"fingerprint"`
	ManifestSHA256   string                       `json:"manifest_sha256"`
	Entries          []folderEntry                `json:"entries"`
	Reservation      folderReservation            `json:"reservation"`
	Staging          *folderReservation           `json:"staging,omitempty"`
	State            string                       `json:"state"`
	Directories      map[string]string            `json:"directories"`
	DirectoryIntents map[string]string            `json:"directory_intents"`
	Files            map[string]folderFileReceipt `json:"files"`
	Uploads          map[string]folderChildUpload `json:"uploads"`
}

type folderGroupStatus struct {
	ID             string             `json:"id"`
	State          string             `json:"state"`
	Path           string             `json:"path,omitempty"`
	ManifestSHA256 string             `json:"manifest_sha256,omitempty"`
	CommittedFiles int                `json:"committed_files"`
	Fingerprint    string             `json:"fingerprint,omitempty"`
	Pane           string             `json:"pane,omitempty"`
	SourceVersion  string             `json:"source_version,omitempty"`
	Child          *folderChildStatus `json:"child,omitempty"`
}

type lockedFolderGroup struct {
	root      string
	lock      *os.File
	record    folderGroupRecord
	durable   []byte
	uncertain bool
}

func (g *lockedFolderGroup) Close() error {
	if g.lock == nil {
		return nil
	}
	err := g.lock.Close() // Closing releases flock even on an error path.
	g.lock = nil
	return err
}

func (g *lockedFolderGroup) status() folderGroupStatus {
	result := folderGroupStatus{ID: g.record.ID, State: g.record.State, ManifestSHA256: g.record.ManifestSHA256, Fingerprint: g.record.Fingerprint, Pane: g.record.Pane, SourceVersion: g.record.SourceVersion}
	if g.record.Reservation.Identity != "" {
		result.Path = filepath.Join(g.record.Reservation.Parent, g.record.Reservation.Name)
	}
	for _, receipt := range g.record.Files {
		if receipt.State == "committed" {
			result.CommittedFiles++
		}
	}
	return result
}

func folderDigestValid(value string) bool {
	raw, err := hex.DecodeString(value)
	return err == nil && len(raw) == 32 && value == strings.ToLower(value)
}

func validateFolderGroup(record folderGroupRecord) error {
	if record.Format != 1 || !validSessionID.MatchString(record.ID) {
		return errors.New("invalid folder group journal")
	}
	// Unseen cancellation is a durable tombstone, independent of any source.
	if record.State == "cancelled" && record.Fingerprint == "" {
		if record.Pane != "" || record.SourceVersion != "" || len(record.Entries) != 0 || record.Reservation.ID != "" || record.Staging != nil || len(record.Files) != 0 || len(record.Uploads) != 0 || len(record.Directories) != 0 || len(record.DirectoryIntents) != 0 || record.ManifestSHA256 != "" {
			return errors.New("invalid folder cancellation tombstone")
		}
		return nil
	}
	canonical, digest, err := canonicalFolderManifest(record.Entries)
	if err != nil || digest != record.ManifestSHA256 || !validSessionID.MatchString(record.Pane) || !folderDigestValid(record.SourceVersion) || !folderDigestValid(record.Fingerprint) {
		return errors.New("invalid folder group source or manifest")
	}
	r := record.Reservation
	if r.Format != 1 || r.ID != record.ID || r.Fingerprint != record.Fingerprint || !filepath.IsAbs(r.Parent) || filepath.Clean(r.Parent) != r.Parent || r.ParentIdentity == "" || !folderChildName(r.Name) {
		return errors.New("invalid folder group reservation binding")
	}
	binding, _ := json.Marshal([]any{record.Pane, record.SourceVersion, digest, r.Parent, r.ParentIdentity, r.Name})
	sum := sha256.Sum256(binding)
	if hex.EncodeToString(sum[:]) != record.Fingerprint {
		return errors.New("folder group binding checksum differs")
	}
	if stage := record.Staging; stage != nil {
		if stage.Format != 1 || stage.ID != record.ID || stage.Fingerprint != record.Fingerprint || stage.Parent != r.Parent || stage.ParentIdentity != r.ParentIdentity || stage.Name != folderStagingName(record.ID) {
			return errors.New("folder staging reservation binding changed")
		}
		if stage.State != "prepared" && stage.State != "reserved" || stage.State == "reserved" && (stage.Identity == "" || !folderDigestValid(stage.Nonce)) {
			return errors.New("invalid folder staging reservation")
		}
	}
	switch record.State {
	case "prepared":
		if r.State != "prepared" {
			return errors.New("invalid prepared folder group")
		}
	case "receiving", "committing", "committed":
		if r.State != "reserved" || r.Identity == "" || !folderDigestValid(r.Nonce) {
			return errors.New("folder group reservation incomplete")
		}
	case "cancelled":
	default:
		return errors.New("invalid folder group state")
	}
	entries := make(map[string]folderEntry, len(canonical))
	for _, entry := range canonical {
		entries[entry.Path] = entry
	}
	for relative, identity := range record.Directories {
		if entries[relative].Kind != "directory" || identity == "" || record.DirectoryIntents[relative] == "" {
			return errors.New("invalid folder directory receipt")
		}
	}
	for relative, parentIdentity := range record.DirectoryIntents {
		expectedParent := r.Identity
		if parent := filepath.Dir(relative); parent != "." {
			expectedParent = record.Directories[parent]
		}
		if entries[relative].Kind != "directory" || parentIdentity == "" || parentIdentity != expectedParent {
			return errors.New("invalid folder directory creation intent")
		}
	}
	for relative, receipt := range record.Files {
		entry := entries[relative]
		if entry.Kind != "file" || receipt.Path != relative || receipt.Size != entry.Size || receipt.SHA256 != entry.SHA256 || !folderChildName(receipt.Stage) || receipt.StageIdentity == "" || receipt.ParentIdentity == "" {
			return errors.New("invalid folder file receipt")
		}
		if receipt.State != "publishing" && receipt.State != "committed" {
			return errors.New("invalid folder file publication state")
		}
		parentIdentity := r.Identity
		if parent := filepath.Dir(relative); parent != "." {
			parentIdentity = record.Directories[parent]
		}
		if parentIdentity == "" || receipt.ParentIdentity != parentIdentity {
			return errors.New("folder file receipt parent differs")
		}
		upload := record.Uploads[relative]
		if upload.State != "receiving" || upload.Stage != receipt.Stage || upload.Identity != receipt.StageIdentity || upload.Offset != entry.Size || upload.PrefixSHA256 != entry.SHA256 {
			return errors.New("folder publication lacks complete durable child upload")
		}
	}
	for relative, upload := range record.Uploads {
		entry := entries[relative]
		if entry.Kind != "file" || record.Staging == nil || record.Staging.State != "reserved" || upload.Stage != folderChildStageName(relative) || upload.Offset < 0 || upload.Offset > entry.Size || !folderDigestValid(upload.PrefixSHA256) {
			return errors.New("invalid folder child upload")
		}
		if upload.State == "prepared" {
			if upload.Identity != "" || upload.Offset != 0 || upload.PrefixSHA256 != folderEmptyDigest() {
				return errors.New("invalid prepared folder child upload")
			}
		} else if upload.State != "receiving" || upload.Identity == "" {
			return errors.New("invalid folder child upload state")
		}
	}
	if record.State == "committed" || record.State == "committing" {
		for _, entry := range canonical {
			if entry.Kind == "directory" && record.Directories[entry.Path] == "" {
				return errors.New("folder directory receipt missing")
			}
			if entry.Kind == "file" && record.Files[entry.Path].State != "committed" {
				return errors.New("folder file receipt missing")
			}
		}
	}
	return nil
}

func lockFolderGroup(stateDir, id string) (*lockedFolderGroup, error) {
	if !validSessionID.MatchString(id) {
		return nil, errors.New("stable folder group ID required")
	}
	if err := EnsurePrivateRuntimeDir(stateDir); err != nil {
		return nil, err
	}
	if err := uploadSyncDirectory(filepath.Dir(stateDir)); err != nil {
		return nil, err
	}
	root := filepath.Join(stateDir, "host-folders")
	if err := EnsurePrivateRuntimeDir(root); err != nil {
		return nil, err
	}
	if err := uploadSyncDirectory(stateDir); err != nil {
		return nil, err
	}
	lock, err := OpenPrivateFile(filepath.Join(root, id+".lock"), os.O_CREATE|os.O_RDWR)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, errors.New("folder group busy; query status later")
	}
	g := &lockedFolderGroup{root: root, lock: lock, record: folderGroupRecord{Format: 1, ID: id}}
	f, err := OpenPrivateFile(filepath.Join(root, id+".json"), os.O_RDONLY)
	if os.IsNotExist(err) {
		return g, nil
	}
	if err != nil {
		g.Close()
		return nil, err
	}
	raw, err := io.ReadAll(io.LimitReader(f, folderJournalLimit+1))
	f.Close()
	if err != nil || len(raw) > folderJournalLimit || json.Unmarshal(raw, &g.record) != nil || g.record.ID != id || validateFolderGroup(g.record) != nil {
		g.Close()
		return nil, errors.New("invalid folder group checkpoint")
	}
	g.durable = raw
	return g, nil
}

func (g *lockedFolderGroup) save() (resultErr error) {
	defer func() {
		if resultErr != nil {
			g.uncertain = true
		}
	}()
	if g.lock == nil || g.uncertain {
		return errors.New("folder group lock closed")
	}
	if err := validateFolderGroup(g.record); err != nil {
		return err
	}
	raw, err := json.Marshal(g.record)
	if err != nil {
		return err
	}
	if len(raw) > folderJournalLimit {
		return errors.New("folder group journal exceeds bounds")
	}
	if len(g.durable) != 0 {
		var previous folderGroupRecord
		if json.Unmarshal(g.durable, &previous) != nil {
			return errors.New("invalid previous folder journal")
		}
		if previous.State == "committed" || previous.State == "cancelled" {
			old, _ := json.Marshal(previous)
			if !bytes.Equal(old, raw) {
				return errors.New("folder group is terminal")
			}
		}
		if previous.ID != g.record.ID || previous.Fingerprint != g.record.Fingerprint {
			return errors.New("folder group binding changed")
		}
		if previous.State == "receiving" && g.record.State == "prepared" || previous.State == "committing" && g.record.State != "committing" && g.record.State != "committed" {
			return errors.New("folder group state cannot regress")
		}
		if previous.Reservation.State == "reserved" && previous.Reservation != g.record.Reservation {
			return errors.New("folder group reservation changed")
		}
		if previous.Staging != nil {
			if g.record.Staging == nil {
				return errors.New("folder staging reservation forgotten")
			}
			if previous.Staging.State == "reserved" && *previous.Staging != *g.record.Staging {
				return errors.New("folder staging reservation changed")
			}
		}
		for relative, identity := range previous.Directories {
			if g.record.Directories[relative] != identity {
				return errors.New("folder directory receipt changed")
			}
		}
		for relative, parentIdentity := range previous.DirectoryIntents {
			if g.record.DirectoryIntents[relative] != parentIdentity {
				return errors.New("folder directory creation intent changed")
			}
		}
		for relative, receipt := range previous.Files {
			next, exists := g.record.Files[relative]
			if !exists || receipt.State == "committed" && receipt != next {
				return errors.New("folder file receipt changed")
			}
			next.State = receipt.State
			if next != receipt {
				return errors.New("folder publication intent changed")
			}
		}
		for relative, upload := range previous.Uploads {
			next, exists := g.record.Uploads[relative]
			if !exists || next.Stage != upload.Stage || next.Offset < upload.Offset || upload.State == "receiving" && (next.State != "receiving" || next.Identity != upload.Identity) || next.Offset == upload.Offset && next.PrefixSHA256 != upload.PrefixSHA256 {
				return errors.New("folder child checkpoint regressed or changed")
			}
		}
	} else if g.record.State != "prepared" && g.record.State != "cancelled" {
		return errors.New("folder group must be prepared before reservation")
	}
	f, err := os.CreateTemp(g.root, ".group-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	n, err := f.Write(raw)
	if err == nil && n != len(raw) {
		err = io.ErrShortWrite
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	g.uncertain = true
	if err = os.Rename(f.Name(), filepath.Join(g.root, g.record.ID+".json")); err != nil {
		return err
	}
	if err = uploadSyncDirectory(g.root); err != nil {
		return err
	}
	g.durable = raw
	g.uncertain = false
	return nil
}

// Must be called only after the RPC layer has resolved and authorized the pane
// and exact destination. The source version is a caller content-tree digest.
func (g *lockedFolderGroup) begin(pane, sourceVersion, parent, name string, entries []folderEntry) error {
	if g.lock == nil || g.uncertain {
		return errors.New("reopen folder group after uncertain journal outcome")
	}
	if g.record.State == "cancelled" {
		return errors.New("folder group cancelled")
	}
	canonical, digest, err := canonicalFolderManifest(entries)
	if err != nil {
		return err
	}
	if !validSessionID.MatchString(pane) || !folderDigestValid(sourceVersion) || !filepath.IsAbs(parent) || filepath.Clean(parent) != parent || !folderChildName(name) {
		return errors.New("exact folder source and destination required")
	}
	fd, err := unix.Open(parent, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	dir := os.NewFile(uintptr(fd), parent)
	info, err := dir.Stat()
	dir.Close()
	if err != nil {
		return err
	}
	binding, _ := json.Marshal([]any{pane, sourceVersion, digest, parent, uploadIdentity(info), name})
	sum := sha256.Sum256(binding)
	fingerprint := hex.EncodeToString(sum[:])
	if len(g.durable) != 0 {
		if g.record.Fingerprint != fingerprint {
			return errors.New("folder ID already bound to another source or destination")
		}
		if g.record.State == "committed" || g.record.State == "committing" {
			return nil
		}
	} else {
		g.record = folderGroupRecord{Format: 1, ID: g.record.ID, Pane: pane, SourceVersion: sourceVersion, Fingerprint: fingerprint, ManifestSHA256: digest, Entries: canonical, State: "prepared", Directories: map[string]string{}, Files: map[string]folderFileReceipt{}, Reservation: folderReservation{Format: 1, ID: g.record.ID, Fingerprint: fingerprint, Parent: parent, ParentIdentity: uploadIdentity(info), Name: name, State: "prepared"}}
		if err := g.save(); err != nil {
			return err
		}
	}
	reservationRoot := filepath.Join(g.root, "reservations")
	r, err := reserveFolder(reservationRoot, g.record.ID, parent, name, fingerprint, g.record.Reservation.ParentIdentity)
	if err != nil {
		return err
	}
	if r.ParentIdentity != g.record.Reservation.ParentIdentity {
		return errors.New("folder parent moved during reservation")
	}
	if g.record.Reservation.State == "reserved" && r != g.record.Reservation {
		return errors.New("folder reservation differs from group checkpoint")
	}
	g.record.Reservation, g.record.State = r, "receiving"
	return g.save()
}

func (g *lockedFolderGroup) cancel() error {
	if g.lock == nil || g.uncertain {
		return errors.New("reopen folder group after uncertain journal outcome")
	}
	if g.record.State == "committed" || g.record.State == "cancelled" {
		return nil
	}
	if g.record.State == "committing" {
		return errors.New("folder commit outcome pending; query status")
	}
	// Preserve published files and the real reserved directory. Garbage
	// collection of private staging follows this durable terminal record.
	g.record.State = "cancelled"
	return g.save()
}

func (g *lockedFolderGroup) openReservedDirectory() (*os.File, error) {
	if g.lock == nil || g.uncertain || g.record.Reservation.State != "reserved" {
		return nil, errors.New("saved folder reservation and active group lock required")
	}
	r := g.record.Reservation
	return openVerifiedFolderReservation(filepath.Join(g.root, "reservations"), r)
}

func openVerifiedFolderReservation(catalog string, r folderReservation) (*os.File, error) {
	verified, err := reserveFolder(catalog, r.ID, r.Parent, r.Name, r.Fingerprint, r.ParentIdentity)
	if err != nil {
		return nil, err
	}
	if verified != r {
		return nil, errors.New("folder reservation journal differs")
	}
	parentFD, err := unix.Open(r.Parent, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	parent := os.NewFile(uintptr(parentFD), r.Parent)
	defer parent.Close()
	info, err := parent.Stat()
	if err != nil || uploadIdentity(info) != r.ParentIdentity {
		return nil, errors.New("reserved folder parent changed")
	}
	fd, err := unix.Openat(parentFD, r.Name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	dir := os.NewFile(uintptr(fd), r.Name)
	info, err = dir.Stat()
	if err != nil || uploadIdentity(info) != r.Identity {
		dir.Close()
		return nil, errors.New("reserved folder identity changed")
	}
	return dir, nil
}

func (g *lockedFolderGroup) commit() error {
	if g.lock == nil || g.uncertain {
		return errors.New("reopen folder group after uncertain journal outcome")
	}
	if g.record.State == "committed" {
		return nil
	}
	if g.record.State != "receiving" && g.record.State != "committing" {
		return errors.New("folder group cannot commit")
	}
	// Journal the intent before inspecting the tree. A failed or interrupted
	// verification remains committing; recovery checks this same reservation.
	if g.record.State == "receiving" {
		previous := g.record.State
		g.record.State = "committing"
		if err := validateFolderGroup(g.record); err != nil {
			g.record.State = previous
			return err
		}
		if err := g.save(); err != nil {
			return err
		}
	}
	dir, err := g.openReservedDirectory()
	if err != nil {
		return err
	}
	defer dir.Close()
	if err := folderVerifyManifest(dir, g.record.Entries, g.record.Directories, g.record.Files); err != nil {
		return err
	}
	// Verify the name and ownership marker again after traversal and flush.
	current, err := g.openReservedDirectory()
	if err != nil {
		return err
	}
	current.Close()
	g.record.State = "committed"
	return g.save()
}
