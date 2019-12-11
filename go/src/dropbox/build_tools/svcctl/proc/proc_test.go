package proc

import (
	"strings"
	"testing"
)

func TestTrue(t *testing.T) {
	p := New("/bin/true")
	if p.Exited() {
		t.Fatalf("Process marked as exited before it was started")
	}
	if err := p.Start(); err != nil {
		t.Fatalf("Start error: %s", err)
	}
	if err := p.Wait(); err != nil {
		t.Fatalf("`true` did not exit cleanly. %s", err)
	}
	if !p.Exited() {
		t.Fatalf("Process not marked as exited after stopping")
	}
	if err := p.Wait(); err != nil {
		t.Fatalf("`true` did not exit cleanly the second time. %s", err)
	}
}

func TestFalse(t *testing.T) {
	p := New("/bin/false")
	if p.Exited() {
		t.Fatalf("Process marked as exited before it was started")
	}
	if err := p.Start(); err != nil {
		t.Fatalf("Start error: %s", err)
	}
	if err := p.Wait(); err == nil {
		t.Fatalf("`false` exited cleanly.")
	}
	if !p.Exited() {
		t.Fatalf("Process not marked as exited after stopping")
	}
	if err := p.Wait(); err == nil {
		t.Fatalf("`false` exited cleanly the second time.")
	}
}

func TestKill(t *testing.T) {
	p := New("/bin/sleep", "infinity")
	if p.Exited() {
		t.Fatalf("Process marked as exited before it was started")
	}
	if err := p.Start(); err != nil {
		t.Fatalf("Start error: %s", err)
	}
	if p.Exited() {
		t.Fatalf("Process marked as exited before it exited")
	}
	if err := p.Cmd.Process.Kill(); err != nil {
		t.Fatalf("Unable to kill process")
	}
	if err := p.Wait(); err == nil {
		t.Fatalf("Killed process exited cleanly.")
	}
	if !p.Exited() {
		t.Fatalf("Process not marked as exited after stopping")
	}
}

func TestGORACE(t *testing.T) {
	p := New("/bin/true")
	if err := p.Start(); err != nil {
		t.Fatalf("Start error: %s", err)
	}
	if err := p.Wait(); err != nil {
		t.Fatalf("`true` did not exit cleanly. %s", err)
	}
	var foundGoRace bool
	for _, e := range p.Cmd.Env {
		if strings.HasPrefix(e, "GORACE=") {
			foundGoRace = true
			break
		}
	}
	if !foundGoRace {
		t.Fatalf("GORACE variable wasn't set")
	}
}
