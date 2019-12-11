package svcctl

import (
	"time"

	"dropbox/build_tools/svcctl/topological"
)

type stopTask struct {
	svc *serviceDef
}

func (st *stopTask) Key() string {
	return st.svc.name
}

func (st *stopTask) Run() error {
	return st.svc.Stop()
}

func (st *stopTask) Dependents() []topological.Task {
	allTasks := make([]topological.Task, 0, len(st.svc.Dependents))
	for _, svc := range st.svc.Dependents {
		allTasks = append(allTasks, &stopTask{svc: svc})
	}
	return allTasks
}

func (st *stopTask) Duration() time.Duration {
	return st.svc.StopDuration()
}

func (st *stopTask) StartTime() time.Time {
	return st.svc.StopTime()
}

func newTopologicalStopper(svcs []*serviceDef) topological.Runner {
	allTasks := make([]topological.Task, 0, len(svcs))
	for _, svc := range svcs {
		allTasks = append(allTasks, &stopTask{svc: svc})
	}
	return topological.NewReversedRunner(allTasks)
}
