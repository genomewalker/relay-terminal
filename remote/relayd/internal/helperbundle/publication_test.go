package helperbundle

import (
	"archive/tar"
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type publicationMove struct{ name, host, mover string }

func publicationMoves() []publicationMove {
	variants := []publicationMove{{"native", "", "/bin/mv"}}
	if gnu, err := exec.LookPath("gmv"); err == nil {
		variants = append(variants, publicationMove{"gnu", "Linux", gnu})
	}
	return variants
}
func publicationPaths() []string {
	return []string{
		".local/share/relay/bin/relayd-linux-amd64",
		".local/share/relay/bin/" + Names[len(Names)-1] + "-linux-amd64",
		".local/share/relay/relay-release.json",
		".local/bin/relayd",
		".local/share/relay/shims/relay-native-tool",
		".local/share/relay/bin/relayd-communication",
		".local/share/relay/bin/relayd-verified",
		".local/share/relay/bin/relay-mcp-communication",
		".local/share/relay/bin/relay-mcp",
		".local/share/relay/bin/relay-peer-link",
	}
}
func changedPublicationArchive(t *testing.T) []byte {
	t.Helper()
	return replaceArchiveEntry(t, archive(t, ""), "not-an-archive-entry", tar.TypeReg)
}
func requirePublicationEntry(t *testing.T, path string) {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	aliases := map[string]string{"relayd-communication": "relayd-linux-amd64", "relayd-verified": "relayd-linux-amd64", "relay-mcp-communication": "relay-mcp-linux-amd64", "relay-mcp": "relay-mcp-linux-amd64", "relay-peer-link": "relay-peer-link-linux-amd64"}
	if strings.Contains(path, "/share/relay/bin/") {
		if target, ok := aliases[filepath.Base(path)]; ok {
			got, e := os.Readlink(path)
			if e != nil || got != target {
				t.Fatalf("PUBLICATION_NOFOLLOW: alias retained foreign target: %s %q %v", path, got, e)
			}
			return
		}
	}
	if !info.Mode().IsRegular() {
		t.Fatalf("PUBLICATION_NOFOLLOW: destination did not become a regular file: %s %v", path, info.Mode())
	}
}
func TestPublicationNeverFollowsDestinationSymlinks(t *testing.T) {
	for _, variant := range publicationMoves() {
		for _, rel := range publicationPaths() {
			for _, directory := range []bool{false, true} {
				kind := map[bool]string{false: "file", true: "directory"}[directory]
				t.Run(variant.name+"/"+rel+"/"+kind, func(t *testing.T) {
					home := t.TempDir()
					if out, e := install(t, home, archive(t, ""), false); e != nil {
						t.Fatalf("setup %v %s", e, out)
					}
					waitForDetachedInstall(t, home)
					destination := filepath.Join(home, rel)
					if e := os.Remove(destination); e != nil {
						t.Fatal(e)
					}
					outside := filepath.Join(home, "user-owned-destination")
					original := []byte("exact user-owned bytes")
					marker := outside
					if directory {
						if e := os.Mkdir(outside, 0700); e != nil {
							t.Fatal(e)
						}
						marker = filepath.Join(outside, "keep")
					}
					if e := os.WriteFile(marker, original, 0600); e != nil {
						t.Fatal(e)
					}
					if e := os.Symlink(outside, destination); e != nil {
						t.Fatal(e)
					}
					if out, e := installWithHost(t, home, changedPublicationArchive(t), false, variant.host, variant.mover); e != nil {
						t.Fatalf("PUBLICATION_NOFOLLOW: publication must replace the destination itself: %v %s", e, out)
					}
					waitForDetachedInstall(t, home)
					data, e := os.ReadFile(marker)
					if e != nil || !bytes.Equal(data, original) {
						t.Fatalf("PUBLICATION_NOFOLLOW: changed foreign target: %s %v", rel, e)
					}
					if directory {
						entries, e := os.ReadDir(outside)
						if e != nil || len(entries) != 1 || entries[0].Name() != "keep" {
							t.Fatalf("PUBLICATION_NOFOLLOW: published inside foreign directory: %s %v %v", rel, entries, e)
						}
					}
					requirePublicationEntry(t, destination)
				})
			}
		}
	}
}
func TestPublicationDirectoryPreflightPreservesInstalledPayloads(t *testing.T) {
	for _, variant := range publicationMoves() {
		for _, rel := range publicationPaths() {
			t.Run(variant.name+"/"+rel, func(t *testing.T) {
				home := t.TempDir()
				if out, e := install(t, home, archive(t, ""), false); e != nil {
					t.Fatalf("setup %v %s", e, out)
				}
				waitForDetachedInstall(t, home)
				destination := filepath.Join(home, rel)
				if e := os.Remove(destination); e != nil {
					t.Fatal(e)
				}
				if e := os.Mkdir(destination, 0700); e != nil {
					t.Fatal(e)
				}
				original := []byte("directory sentinel")
				marker := filepath.Join(destination, "keep")
				if e := os.WriteFile(marker, original, 0600); e != nil {
					t.Fatal(e)
				}
				payloadRoot := filepath.Join(home, ".local/share/relay/bin")
				before := fileBytes(t, payloadRoot)
				if out, e := installWithHost(t, home, changedPublicationArchive(t), false, variant.host, variant.mover); e == nil {
					t.Fatalf("PUBLICATION_PREFLIGHT: directory destination admitted: %s %s", rel, out)
				}
				after := fileBytes(t, payloadRoot)
				if !reflect.DeepEqual(before, after) {
					t.Fatalf("PUBLICATION_PREFLIGHT: replaced a payload before rejecting destination: %s", rel)
				}
				data, e := os.ReadFile(marker)
				if e != nil || !bytes.Equal(data, original) {
					t.Fatalf("PUBLICATION_PREFLIGHT: directory sentinel changed: %s %v", rel, e)
				}
				entries, e := os.ReadDir(destination)
				if e != nil || len(entries) != 1 || entries[0].Name() != "keep" {
					t.Fatalf("PUBLICATION_PREFLIGHT: wrote inside directory: %s %v %v", rel, entries, e)
				}
			})
		}
	}
}
