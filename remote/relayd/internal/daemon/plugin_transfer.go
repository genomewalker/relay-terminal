package daemon

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

const pluginTransferChunk = 4 << 20
const pluginTransferMaximum = int64(64) << 30

type PluginTransferRequest struct {
	Mode    string `json:"mode"`
	Version string `json:"version"`
	Offset  int64  `json:"offset"`
}
type PluginTransferInfo struct {
	Version string `json:"version"`
	Size    int64  `json:"size"`
	Offset  int64  `json:"offset"`
	SHA256  string `json:"sha256,omitempty"`
}

func transferVersion(info os.FileInfo) string {
	// File identity plus metadata: replacing a path is not a valid resume.
	stat, _ := info.Sys().(*syscall.Stat_t)
	identity := fmt.Sprintf("%d:%d:%v", info.Size(), info.ModTime().UnixNano(), info.Mode())
	if stat != nil {
		identity += fmt.Sprintf(":%d:%d", stat.Dev, stat.Ino)
	}
	sum := sha256.Sum256([]byte(identity))
	return hex.EncodeToString(sum[:])
}

func pluginTransfer(root *os.Root, request PluginRequest, result *PluginResult) error {
	t := request.Transfer
	if request.Path == "" || filepath.IsAbs(request.Path) || strings.ContainsRune(request.Path, 0) {
		return errors.New("select one relative file")
	}
	for _, c := range strings.Split(request.Path, "/") {
		if c == ".." || c == "." || c == "" {
			return errors.New("invalid relative file")
		}
	}
	if t.Mode != "stat" && t.Mode != "chunk" && t.Mode != "verify" {
		return errors.New("invalid transfer mode")
	}
	f, err := root.OpenFile(request.Path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() > pluginTransferMaximum {
		return errors.New("transfer requires a regular file no larger than 64 GiB")
	}
	version := transferVersion(info)
	if t.Offset < 0 || t.Offset > info.Size() {
		return errors.New("invalid transfer offset")
	}
	if t.Mode != "stat" && (t.Version == "" || t.Version != version) {
		return errors.New("source changed; discard the partial transfer and start again")
	}
	result.Text = request.Path
	result.Transfer = &PluginTransferInfo{Version: version, Size: info.Size(), Offset: t.Offset}
	if t.Mode == "chunk" {
		count := min(int64(pluginTransferChunk), info.Size()-t.Offset)
		data := make([]byte, int(count))
		if _, err = f.ReadAt(data, t.Offset); err != nil && !(err == io.EOF && count == 0) {
			return err
		}
		sum := sha256.Sum256(data)
		encoded := base64.StdEncoding.EncodeToString(data)
		result.Content = &encoded
		result.SHA256 = hex.EncodeToString(sum[:])
	} else if t.Mode == "verify" {
		h := sha256.New()
		if _, err = io.Copy(h, io.LimitReader(f, info.Size()+1)); err != nil {
			return err
		}
		result.Transfer.SHA256 = hex.EncodeToString(h.Sum(nil))
	}
	after, err := f.Stat()
	if err != nil {
		return err
	}
	if transferVersion(after) != version {
		return errors.New("source changed during transfer")
	}
	return nil
}
