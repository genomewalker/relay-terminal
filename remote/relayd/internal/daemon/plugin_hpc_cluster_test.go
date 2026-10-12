package daemon

import (
	"reflect"
	"testing"
)

func TestHPCClusterDeduplicatesNodes(t *testing.T) {
	c, err := inspectHPCCluster("/tmp", func(root, name string, args ...string) (string, error) {
		if root != "/tmp" || name != "sinfo" || !reflect.DeepEqual(args, []string{"--Node", "--noheader", pluginClusterFormat}) {
			t.Fatal(root, name, args)
		}
		return "n1\x1f12/84/0/96\x1f1024\x1fmix\nn1\x1f12/84/0/96\x1f1024\x1fmix\nn2\x1f0/0/96/96\x1f2048\x1fdown\n", nil
	})
	if err != nil || c.Nodes != 2 || c.Allocated != 12 || c.Idle != 84 || c.Other != 96 || c.Total != 192 || c.MemoryMiB != 3072 {
		t.Fatal(c, err)
	}
}

func TestHPCClusterMemoryAndGPUs(t *testing.T) {
	c, err := inspectHPCCluster("/tmp", func(string, string, ...string) (string, error) {
		return "gpu1\x1f8/8/0/16\x1f32768\x1f16384\x1fgpu:a100:4(S:0-1)\x1fgpu:a100:2(IDX:0-1)\n", nil
	})
	if err != nil || c.GPUs != 4 || c.UsedGPUs != 2 || c.AllocatedMemoryMiB != 16384 {
		t.Fatal(c, err)
	}
}

func TestHPCClusterRejectsInconsistentCounts(t *testing.T) {
	for _, out := range []string{"n\x1f1/2/3/9\x1f1024\x1fmix", "n\x1f-1/2/3/4\x1f1024\x1fmix", "malformed"} {
		if _, err := inspectHPCCluster("/tmp", func(string, string, ...string) (string, error) { return out, nil }); err == nil {
			t.Fatal("accepted", out)
		}
	}
}
