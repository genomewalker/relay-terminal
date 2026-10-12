package daemon

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"

	"golang.org/x/sys/unix"
)

const hostNativeClaimDirectory = "rotation-native-claims"
const hostNativeClaimRecordLimit = 64 << 10

type hostNativeClaimJournal struct {
	workerDirectory string
	sessionID       string
	operationID     string
	requestSHA256   string
}

type hostNativeClaimActive struct {
	Version       int    `json:"v"`
	OperationID   string `json:"operation_id"`
	RequestSHA256 string `json:"request_sha256"`
}

type hostNativeClaimPhase struct {
	Version       int                     `json:"v"`
	State         string                  `json:"state"`
	RequestSHA256 string                  `json:"request_sha256"`
	Claim         *hostNativeClaimReceipt `json:"claim,omitempty"`
}

// The lock covers only bounded local file operations, never an RPC or native
// action. The active source entry survives crashes and blocks a fresh attempt.
func lockHostNativeClaimRoot(workerDirectory string, create bool) (*os.File, *os.File, error) {
	root, err := openHostRotationPrivateRoot(workerDirectory, hostNativeClaimDirectory, create)
	if err != nil {
		return nil, nil, err
	}
	flags := unix.O_RDWR | unix.O_CLOEXEC | unix.O_NOFOLLOW | unix.O_NONBLOCK
	if create {
		flags |= unix.O_CREAT
	}
	fd, err := unix.Openat(int(root.Fd()), "lock", flags, 0o600)
	if err != nil {
		root.Close()
		return nil, nil, err
	}
	lock := os.NewFile(uintptr(fd), "native-claim-lock")
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil || st.Uid != uint32(os.Getuid()) || st.Nlink != 1 ||
		st.Mode&unix.S_IFMT != unix.S_IFREG || st.Mode&0o077 != 0 {
		lock.Close()
		root.Close()
		return nil, nil, errors.New("native claim lock is not private")
	}
	if err := unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB); err != nil {
		lock.Close()
		root.Close()
		return nil, nil, errors.New("native claim journal busy")
	}
	return root, lock, nil
}

func readHostNativeClaimFile(root *os.File, name string) ([]byte, error) {
	fd, err := unix.Openat(int(root.Fd()), name, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), name)
	defer file.Close()
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil || st.Uid != uint32(os.Getuid()) || st.Nlink != 1 ||
		st.Mode&unix.S_IFMT != unix.S_IFREG || st.Mode&0o077 != 0 || st.Size <= 0 || st.Size > hostNativeClaimRecordLimit {
		return nil, errors.New("native claim record is not private or bounded")
	}
	before, err := file.Stat()
	if err != nil {
		return nil, err
	}
	data, err := io.ReadAll(io.LimitReader(file, hostNativeClaimRecordLimit+1))
	if err != nil {
		return nil, err
	}
	after, err := file.Stat()
	if err != nil || !sameRotationSourceFile(before, after) || len(data) > hostNativeClaimRecordLimit ||
		!rotationSourceJSONUnambiguous(data) {
		return nil, errors.New("native claim record changed or is incomplete")
	}
	if err := file.Sync(); err != nil {
		return nil, err
	}
	return data, nil
}

func writeHostNativeClaimFile(root *os.File, name string, data []byte, reuse bool) error {
	if len(data) == 0 || len(data) > hostNativeClaimRecordLimit {
		return errors.New("native claim record exceeds limit")
	}
	fd, err := unix.Openat(int(root.Fd()), name, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0o600)
	if err != nil {
		if reuse && errors.Is(err, unix.EEXIST) {
			saved, readErr := readHostNativeClaimFile(root, name)
			if readErr == nil && bytes.Equal(saved, data) {
				// A previous successful phase is descriptive evidence only.
				// No action may be resubmitted from this path.
				return root.Sync()
			}
		}
		return err
	}
	file := os.NewFile(uintptr(fd), name)
	_, err = file.Write(data)
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return root.Sync()
}

func beginHostNativeClaim(workerDirectory string, request hostNativeClaimRequest) (*hostNativeClaimJournal, error) {
	if !validHostNativeUUID(request.SessionID) || !validHostNativeUUID(request.Epoch) {
		return nil, errors.New("invalid native claim journal identity")
	}
	data, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	j := &hostNativeClaimJournal{workerDirectory: workerDirectory, sessionID: request.SessionID,
		operationID: request.Epoch, requestSHA256: hostRotationCapsuleHash(data)}
	root, lock, err := lockHostNativeClaimRoot(workerDirectory, true)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	defer lock.Close()
	_, err = readHostNativeClaimFile(root, j.sessionID+".active.json")
	if !errors.Is(err, os.ErrNotExist) {
		return nil, errors.New("native claim reconciliation required")
	}
	// Request bytes are immutable. Even a reused UUID with identical bytes is
	// refused; a lost response must be reconciled by the existing operation.
	if err := writeHostNativeClaimFile(root, j.operationID+".request.json", data, false); err != nil {
		return nil, err
	}
	active, _ := json.Marshal(hostNativeClaimActive{1, j.operationID, j.requestSHA256})
	if err := writeHostNativeClaimFile(root, j.sessionID+".active.json", active, false); err != nil {
		return nil, err
	}
	return j, nil
}

func (j *hostNativeClaimJournal) checkActive(root *os.File) error {
	data, err := readHostNativeClaimFile(root, j.sessionID+".active.json")
	if err != nil {
		return err
	}
	var active hostNativeClaimActive
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&active) != nil || active != (hostNativeClaimActive{1, j.operationID, j.requestSHA256}) {
		return errors.New("native claim journal owner changed")
	}
	request, err := readHostNativeClaimFile(root, j.operationID+".request.json")
	if err != nil || hostRotationCapsuleHash(request) != j.requestSHA256 {
		return errors.New("native claim request changed")
	}
	return nil
}

func (j *hostNativeClaimJournal) record(state string, claim *hostNativeClaimReceipt) error {
	if state != "claim_uncertain" && claim == nil {
		return errors.New("native claim phase needs a receipt")
	}
	if claim != nil && (claim.SessionID != j.sessionID || claim.Epoch != j.operationID || claim.OperationID != j.operationID) {
		return errors.New("native claim phase identity changed")
	}
	switch state {
	case "claim_received", "claim_uncertain", "release_requested", "released":
	default:
		return errors.New("invalid native claim phase")
	}
	root, lock, err := lockHostNativeClaimRoot(j.workerDirectory, false)
	if err != nil {
		return err
	}
	defer root.Close()
	defer lock.Close()
	if err := j.checkActive(root); err != nil {
		return err
	}
	if state == "release_requested" || state == "released" {
		_, err := readHostNativeClaimFile(root, j.operationID+".commit_requested.json")
		if !errors.Is(err, os.ErrNotExist) {
			return errors.New("native commit requires reconciliation")
		}
	}
	data, err := json.Marshal(hostNativeClaimPhase{1, state, j.requestSHA256, claim})
	if err != nil {
		return err
	}
	// The release intent is a one-shot action boundary, not a replayable phase.
	return writeHostNativeClaimFile(root, j.operationID+"."+state+".json", data, state != "release_requested")
}

func (j *hostNativeClaimJournal) finishRelease(claim hostNativeClaimReceipt) error {
	if !claim.Closed || claim.ReleaseSeq <= claim.Seq {
		return errors.New("native release receipt unavailable")
	}
	root, lock, err := lockHostNativeClaimRoot(j.workerDirectory, false)
	if err != nil {
		return err
	}
	defer root.Close()
	defer lock.Close()
	if err := j.checkActive(root); err != nil {
		return err
	}
	_, err = readHostNativeClaimFile(root, j.operationID+".commit_requested.json")
	if !errors.Is(err, os.ErrNotExist) {
		return errors.New("native commit requires reconciliation")
	}
	intent, err := readHostNativeClaimFile(root, j.operationID+".release_requested.json")
	if err != nil {
		return err
	}
	var requested hostNativeClaimPhase
	decoder := json.NewDecoder(bytes.NewReader(intent))
	decoder.DisallowUnknownFields()
	matching := claim
	matching.Closed = false
	matching.ReleaseSeq = 0
	if decoder.Decode(&requested) != nil || requested.Version != 1 || requested.State != "release_requested" ||
		requested.RequestSHA256 != j.requestSHA256 || requested.Claim == nil || matching != *requested.Claim {
		return errors.New("native release does not match durable intent")
	}
	data, err := json.Marshal(hostNativeClaimPhase{1, "released", j.requestSHA256, &claim})
	if err != nil {
		return err
	}
	if err := writeHostNativeClaimFile(root, j.operationID+".released.json", data, true); err != nil {
		return err
	}
	if err := unix.Unlinkat(int(root.Fd()), j.sessionID+".active.json", 0); err != nil {
		return err
	}
	return root.Sync()
}
