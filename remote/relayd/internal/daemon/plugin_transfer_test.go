package daemon

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

func TestPluginChunkedTransfer(t *testing.T) {
	root := t.TempDir()
	data := bytes.Repeat([]byte("abc"), 3<<20)
	if err := os.WriteFile(filepath.Join(root, "large"), data, 0600); err != nil {
		t.Fatal(err)
	}
	req := PluginRequest{Operation: "transfers", Root: root, Path: "large", Transfer: &PluginTransferRequest{Mode: "stat"}}
	stat, err := InspectPlugin(req)
	if err != nil {
		t.Fatal(err)
	}
	if stat.Content != nil || stat.Transfer.Size != int64(len(data)) {
		t.Fatal(stat)
	}
	var received []byte
	for offset := int64(0); offset < int64(len(data)); {
		req.Transfer = &PluginTransferRequest{Mode: "chunk", Version: stat.Transfer.Version, Offset: offset}
		chunk, err := InspectPlugin(req)
		if err != nil {
			t.Fatal(err)
		}
		decoded, err := base64.StdEncoding.DecodeString(*chunk.Content)
		if err != nil {
			t.Fatal(err)
		}
		if len(decoded) > pluginTransferChunk {
			t.Fatal("unbounded chunk")
		}
		received = append(received, decoded...)
		offset += int64(len(decoded))
	}
	req.Transfer = &PluginTransferRequest{Mode: "verify", Version: stat.Transfer.Version, Offset: int64(len(data))}
	verified, err := InspectPlugin(req)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(received)
	if !bytes.Equal(data, received) || verified.Transfer.SHA256 != hex.EncodeToString(hash[:]) {
		t.Fatal("integrity mismatch")
	}
	if err := os.WriteFile(filepath.Join(root, "large"), []byte("changed"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = InspectPlugin(req); err == nil {
		t.Fatal("resumed changed source")
	}
}

func TestPluginTransferConfinementAndEmpty(t *testing.T) {
	root := t.TempDir()
	outside := filepath.Join(t.TempDir(), "secret")
	os.WriteFile(outside, []byte("secret"), 0600)
	os.Symlink(outside, filepath.Join(root, "escape"))
	os.WriteFile(filepath.Join(root, "empty"), nil, 0600)
	for _, path := range []string{"escape", "../secret", "/etc/passwd", "."} {
		_, err := InspectPlugin(PluginRequest{Operation: "transfers", Root: root, Path: path, Transfer: &PluginTransferRequest{Mode: "stat"}})
		if err == nil {
			t.Fatal("accepted", path)
		}
	}
	req := PluginRequest{Operation: "transfers", Root: root, Path: "empty", Transfer: &PluginTransferRequest{Mode: "stat"}}
	stat, err := InspectPlugin(req)
	if err != nil {
		t.Fatal(err)
	}
	req.Transfer = &PluginTransferRequest{Mode: "verify", Version: stat.Transfer.Version}
	verified, err := InspectPlugin(req)
	sum := sha256.Sum256(nil)
	if err != nil || verified.Transfer.SHA256 != hex.EncodeToString(sum[:]) {
		t.Fatal(verified, err)
	}
	req.Transfer.Offset = -1
	if _, err := InspectPlugin(req); err == nil {
		t.Fatal("negative offset")
	}
}
