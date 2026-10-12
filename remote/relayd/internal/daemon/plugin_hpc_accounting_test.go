package daemon

import (
	"strings"
	"testing"
)

func TestHPCAccountingOwnershipAndReadOnly(t *testing.T) {
	row := "12|1000|test|COMPLETED|cpu|60|2|1|00:01:00|120|2Gc|500M|0:0|today|today|today|a|cpu=2|cpu=2|\n"
	run := func(root, command string, args ...string) (string, error) {
		if command != "sacct" || !strings.Contains(strings.Join(args, " "), "--uid 1000") {
			t.Fatal(command, args)
		}
		return row, nil
	}
	got, rows, err := inspectHPCAccounting("/", "12", 1000, run)
	if err != nil || len(rows) != 1 || rows[0][9] != "120" {
		t.Fatal(got, err)
	}
	row = strings.Replace(row, "|1000|", "|999|", 1)
	if _, _, err = inspectHPCAccounting("/", "12", 1000, run); err == nil {
		t.Fatal("foreign owner accepted")
	}
	row = "broken"
	if _, _, err = inspectHPCAccounting("/", "12", 1000, run); err == nil {
		t.Fatal("malformed accepted")
	}
	if _, _, err = inspectHPCAccounting("/", "12;touch /tmp/x", 1000, run); err == nil {
		t.Fatal("invalid id accepted")
	}
}

func TestHPCAccountingEmptyFinalFieldAndArrayTask(t *testing.T) {
	raw := "12_[3]|1000|array|COMPLETED|cpu|60|2|1|00:01:00|120|2Gc||0:0|today|today|today|a|cpu=2|\n"
	run := func(root, command string, args ...string) (string, error) {
		joined := strings.Join(args, " ")
		if strings.Contains(joined, "--array") || !strings.Contains(joined, "--allocations") {
			t.Fatal(joined)
		}
		return raw, nil
	}
	_, rows, err := inspectHPCAccounting("/", "", 1000, run)
	if err != nil || len(rows) != 1 || rows[0][0] != "12_3" || rows[0][18] != "" {
		t.Fatal(rows, err)
	}
}
