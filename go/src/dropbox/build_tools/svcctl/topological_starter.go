package svcctl

import (
	"time"

	"dropbox/build_tools/svcctl/topological"
)

type startTask struct {
	svc *serviceDef
}

func (st *startTask) Key() string {
	return st.svc.name
}

func (st *startTask) Run() error {
	startErr := st.svc.Start()
	if startErr != nil {
		return startErr
	}
	return st.svc.waitTillHealthy()
}

func (st *startTask) Dependents() []topological.Task {
	allTasks := make([]topological.Task, 0, len(st.svc.Dependents))
	for _, svc := range st.svc.Dependents {
		allTasks = append(allTasks, &startTask{svc: svc})
	}
	return allTasks
}

func (st *startTask) Duration() time.Duration {
	return st.svc.StartDuration()
}

func (st *startTask) StartTime() time.Time {
	return st.svc.StartTime()
}

func newTopologicalStarter(svcs []*serviceDef) topological.Runner {
	allTasks := make([]topological.Task, 0, len(svcs))
	for _, svc := range svcs {
		allTasks = append(allTasks, &startTask{svc: svc})
	}
	return topological.NewRunner(allTasks)
}
