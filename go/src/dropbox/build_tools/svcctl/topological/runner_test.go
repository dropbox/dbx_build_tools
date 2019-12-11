package topological

import (
	"testing"
	"time"
)

type dummyTask struct {
	key        string
	startTime  time.Time
	started    bool
	dependents []Task
}

func (dt *dummyTask) Key() string {
	return dt.key
}

func (dt *dummyTask) Run() error {
	dt.started = true
	dt.startTime = time.Now()
	return nil
}

func (dt *dummyTask) Dependents() []Task {
	return dt.dependents
}

func (dt *dummyTask) Duration() time.Duration {
	return 0
}

func (dt *dummyTask) StartTime() time.Time {
	if !dt.started {
		panic("Not started yet")
	}
	return dt.startTime
}

func startedFirst(t *testing.T, msg string, first *dummyTask, second *dummyTask) {
	firstStartedTime := first.StartTime().Add(first.Duration())
	secondStartedTime := second.StartTime().Add(second.Duration())
	if secondStartedTime.Before(firstStartedTime) {
		t.Logf("%v %v < %v", msg, firstStartedTime, secondStartedTime)
		t.Fail()
	}
}

func TestStartInOrderLinear(t *testing.T) {
	s1 := &dummyTask{
		key: "1234",
	}
	s2 := &dummyTask{
		key:        "1235",
		dependents: []Task{s1},
	}

	runner := NewRunner([]Task{s2})
	runner.Run()
	startedFirst(t, "s1 before s2", s1, s2)
}

func TestReversedStartInOrderLinear(t *testing.T) {
	s1 := &dummyTask{
		key: "1234",
	}
	s2 := &dummyTask{
		key:        "1235",
		dependents: []Task{s1},
	}

	runner := NewReversedRunner([]Task{s2})
	runner.Run()
	startedFirst(t, "s2 before s1", s2, s1)
}

func TestStartInOrderDiamond(t *testing.T) {
	bottom := &dummyTask{
		key: "1234",
	}
	left := &dummyTask{
		key:        "1235",
		dependents: []Task{bottom},
	}
	right := &dummyTask{
		key:        "1236",
		dependents: []Task{bottom},
	}
	top := &dummyTask{
		key:        "1237",
		dependents: []Task{left, right},
	}

	runner := NewRunner([]Task{top})
	runner.Run()

	if runner.Completed() != 4 {
		t.Errorf("should have started 4 unique tasks but claimed %v", runner.Completed())
	}

	startedFirst(t, "left before top", left, top)
	startedFirst(t, "right before top", right, top)
	startedFirst(t, "bottom before top", bottom, top)

	startedFirst(t, "bottom before left", bottom, left)
	startedFirst(t, "bottom before right", bottom, right)
}

func TestRestartInOrderDiamond(t *testing.T) {
	bottom := &dummyTask{
		key: "1234",
	}
	left := &dummyTask{
		key:        "1235",
		dependents: []Task{bottom},
	}
	right := &dummyTask{
		key:        "1236",
		dependents: []Task{bottom},
	}
	top := &dummyTask{
		key:        "1237",
		dependents: []Task{left, right},
	}

	runner := NewReversedRunner([]Task{top})
	runner.Run()

	startedFirst(t, "top before left", top, left)
	startedFirst(t, "top before right", top, right)
	startedFirst(t, "top before bottom", top, bottom)

	startedFirst(t, "left before bottom", left, bottom)
	startedFirst(t, "right before bottom", right, bottom)
}
