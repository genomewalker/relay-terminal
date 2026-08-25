package daemon

import "testing"

func TestArtifactDetectorFindsSplitPathOnce(t *testing.T) {
	var detector artifactDetector
	if got := detector.ingest([]byte("Saved file:///home/user/generated/im")); len(got) != 0 {
		t.Fatalf("unexpected partial match: %v", got)
	}
	got := detector.ingest([]byte("age.png\r\n"))
	if len(got) != 1 || got[0] != "/home/user/generated/image.png" {
		t.Fatalf("unexpected match: %v", got)
	}
	if duplicate := detector.ingest([]byte("again /home/user/generated/image.png")); len(duplicate) != 0 {
		t.Fatalf("duplicate match: %v", duplicate)
	}
}
