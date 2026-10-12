package daemon

import (
	"encoding/json"
	"os"
	"testing"
)

func TestFolderNativeCanonicalFixture(t *testing.T) {
	path := os.Getenv("RELAY_FOLDER_NATIVE_CANONICAL_PROOF")
	if path == "" { t.Skip("native canonical fixture not supplied") }
	raw,err := os.ReadFile(path)
	if err != nil { t.Fatal(err) }
	var fixture struct { Entries []folderEntry `json:"entries"`; ManifestSHA256 string `json:"manifestSHA256"` }
	if err := json.Unmarshal(raw,&fixture); err != nil { t.Fatal(err) }
	_,digest,err := canonicalFolderManifest(fixture.Entries)
	if err != nil || digest != fixture.ManifestSHA256 { t.Fatalf("native/Go manifest mismatch %s %s %v",digest,fixture.ManifestSHA256,err) }
}
