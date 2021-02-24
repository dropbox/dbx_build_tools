package state_machine

import (
	"sync"

	svclib_proto "dropbox/proto/build_tools/svclib"
)

// a threadsafe representation of a state in a state machine
// this does not give us the safety normally associated with
// a state machine, like ensuring valid transitions. That will require
// refactoring daemon vs. task services, since they have different transition
// diagrams.
type StateMachine interface {
	GetState() svclib_proto.StatusResp_StatusCode
	SetState(newState svclib_proto.StatusResp_StatusCode)
	WaitTillNotState(notState svclib_proto.StatusResp_StatusCode) svclib_proto.StatusResp_StatusCode
}

type stateMachine struct {
	lock        sync.Mutex
	state       svclib_proto.StatusResp_StatusCode
	stateChange *sync.Cond
}

func New(initialState svclib_proto.StatusResp_StatusCode) StateMachine {
	s := &stateMachine{state: initialState}
	s.stateChange = sync.NewCond(&s.lock)
	return s
}

func (s *stateMachine) GetState() svclib_proto.StatusResp_StatusCode {
	s.lock.Lock()
	defer s.lock.Unlock()
	return s.state
}

func (s *stateMachine) SetState(newState svclib_proto.StatusResp_StatusCode) {
	s.lock.Lock()
	defer s.lock.Unlock()
	s.state = newState
	s.stateChange.Broadcast()
}

func (s *stateMachine) WaitTillNotState(notState svclib_proto.StatusResp_StatusCode) svclib_proto.StatusResp_StatusCode {
	s.lock.Lock()
	defer s.lock.Unlock()
	for s.state == notState {
		s.stateChange.Wait()
	}
	return s.state
}
