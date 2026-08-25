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
	detector.markLoaded(got[0])
	if duplicate := detector.ingest([]byte("again /home/user/generated/image.png")); len(duplicate) != 0 {
		t.Fatalf("duplicate match: %v", duplicate)
	}
}

func TestArtifactDetectorFindsExtensionlessClaudeScratchImage(t *testing.T) {
	var detector artifactDetector
	got := detector.ingest([]byte("  /tmp/claude-363159793/project/run/scratchp (3.3KB)\r\n"))
	if len(got) != 1 || got[0] != "/tmp/claude-363159793/project/run/scratchp" {
		t.Fatalf("unexpected Claude scratch match: %v", got)
	}
}

func TestInlineImageMagic(t *testing.T) {
	if !isInlineImage([]byte("\x89PNG\r\n\x1a\ncontent")) ||
		!isInlineImage([]byte("RIFF1234WEBPcontent")) || isInlineImage([]byte("not an image")) {
		t.Fatal("inline image format validation failed")
	}
}
