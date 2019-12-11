package topological

import (
	"runtime"
	"sync"
	"time"
)

type Task interface {
	Key() string
	Run() error
	Dependents() []Task
	Duration() time.Duration
	StartTime() time.Time
}

type Runner interface {
	Run() error
	CriticalPath() []Task
	Completed() int
}

type runner struct {
	wg        *sync.WaitGroup
	cv        *sync.Cond
	startTime time.Time
	costs     map[string]time.Duration

	// the CV's lock protects below values while the pool is running
	tasks      []Task
	tasksByKey map[string]Task
	completed  map[string]bool
	die        bool
	err        error
}

func NewRunner(tasks []Task) Runner {
	tasks = uniqueDeps(tasks)
	tasksByKey := map[string]Task{}
	for _, task := range tasks {
		tasksByKey[task.Key()] = task
	}
	return &runner{
		wg:         &sync.WaitGroup{},
		cv:         sync.NewCond(&sync.Mutex{}),
		startTime:  time.Now(),
		costs:      make(map[string]time.Duration),
		tasks:      tasks,
		tasksByKey: tasksByKey,
		completed:  make(map[string]bool),
	}
}

type reversedTask struct {
	task       Task
	dependents []Task
}

func (t *reversedTask) Key() string {
	return t.task.Key()
}

func (t *reversedTask) Run() error {
	return t.task.Run()
}

func (t *reversedTask) Dependents() []Task {
	return t.dependents
}

func (t *reversedTask) Duration() time.Duration {
	return t.task.Duration()
}

func (t *reversedTask) StartTime() time.Time {
	return t.task.StartTime()
}

// run things in the reversed dependency order
func NewReversedRunner(tasks []Task) Runner {
	reversedDeps := map[string][]Task{}
	seen := map[string]bool{}
	allTasks := []Task{}
	for len(tasks) != 0 {
		task := tasks[0]
		tasks = tasks[1:]
		if seen[task.Key()] {
			continue
		}
		seen[task.Key()] = true
		allTasks = append(allTasks, task)
		for _, dep := range task.Dependents() {
			reversedDeps[dep.Key()] = append(reversedDeps[dep.Key()], task)
			tasks = append(tasks, dep)
		}
	}
	allReversedTasks := make([]Task, 0, len(allTasks))
	reversedTasksByKey := map[string]*reversedTask{}
	for _, task := range allTasks {
		task := &reversedTask{
			task: task,
		}
		allReversedTasks = append(allReversedTasks, task)
		reversedTasksByKey[task.Key()] = task
	}
	for _, task := range reversedTasksByKey {
		for _, dep := range reversedDeps[task.task.Key()] {
			task.dependents = append(task.dependents, reversedTasksByKey[dep.Key()])
		}
	}
	return NewRunner(allReversedTasks)
}

func uniqueDeps(tasks []Task) []Task {
	seen := make(map[string]bool)
	deps := make([]Task, 0)
	queue := make([]Task, 0)
	for _, task := range tasks {
		queue = append(queue, task)
	}

	for len(queue) > 0 {
		task := queue[0]
		queue = queue[1:]
		if !seen[task.Key()] {
			seen[task.Key()] = true
			for _, dep := range task.Dependents() {
				queue = append(queue, dep)
			}
			deps = append(deps, task)
		}
	}
	return deps
}

func (ts *runner) ready(task Task) bool {
	// A task is ready if all its dependencies are marked completed
	// Must be called while holding cv.L.
	for _, dep := range task.Dependents() {
		if !ts.completed[dep.Key()] {
			return false
		}
	}
	return true
}

func (ts *runner) nextTask() Task {
	// Find the next task to run by looping over tasks and checking if it
	// is ready. If nothing is ready we wait on the CV. I had a real
	// topological sort before but that was a pain to use in parallel and the
	// number of tasks is always tiny and computers are fast.
	for i, task := range ts.tasks {
		if ts.ready(task) {
			ts.tasks = append(ts.tasks[:i], ts.tasks[i+1:]...)
			return task
		}
	}
	ts.cv.Wait()
	return nil
}

func (ts *runner) setErr(err error) {
	// Set an error and let everyone else know it is time to die.
	if ts.err != nil {
		// We only care about the first error
		return
	}
	ts.err = err
	ts.die = true
	ts.cv.Broadcast()
}

func (ts *runner) markDone(task Task) {
	// Mark this task as done and let other workers know.
	ts.completed[task.Key()] = true
	// We do not have a reverse dependency map so just wake all the workers. It
	// would only give an upper bound on the number of workers to wake anyway.
	ts.cv.Broadcast()
}

func (ts *runner) worker(id int) {
	// As long as we have tasks and it is not time to die keep starting
	// thing.
	ts.cv.L.Lock()
	for len(ts.tasks) > 0 && !ts.die {
		task := ts.nextTask()
		if task == nil {
			continue
		}
		ts.cv.L.Unlock()

		performErr := task.Run()
		ts.cv.L.Lock()
		if performErr != nil {
			ts.setErr(performErr)
			break
		}

		ts.markDone(task)
	}
	ts.cv.L.Unlock()
	ts.wg.Done()
}

func (ts *runner) Run() error {
	for i := 0; i <= runtime.NumCPU()*2; i++ {
		ts.wg.Add(1)
		go ts.worker(i)
	}
	ts.wg.Wait()
	return ts.err
}

func (ts *runner) highestCost(tasks []Task) Task {
	if len(tasks) == 0 {
		return nil
	}
	var highest Task
	cost := 0 * time.Second
	for _, task := range tasks {
		// If you were already running you can't be in the critical path
		if task.StartTime().Before(ts.startTime) {
			continue
		}
		taskCost := ts.taskCost(task)
		if cost < taskCost {
			cost = taskCost
			highest = task
		}
	}
	return highest
}

func (ts *runner) taskCost(task Task) time.Duration {
	if task == nil {
		return 0
	}
	if _, present := ts.costs[task.Key()]; !present {
		ts.costs[task.Key()] = task.Duration() + ts.taskCost(ts.highestCost(task.Dependents()))
	}
	return ts.costs[task.Key()]
}

func (ts *runner) CriticalPath() []Task {
	// Returns the slowest chain of tasks
	ts.cv.L.Lock()
	defer ts.cv.L.Unlock()

	criticalPath := make([]Task, 0)
	allTasks := make([]Task, 0, len(ts.completed))
	for key := range ts.completed {
		allTasks = append(allTasks, ts.tasksByKey[key])
	}
	task := ts.highestCost(allTasks)
	for task != nil {
		criticalPath = append(criticalPath, task)
		task = ts.highestCost(task.Dependents())
	}
	return criticalPath
}

// Return how many unique tasks were run.
func (ts *runner) Completed() int {
	return len(ts.completed)
}
