package svcctl

import (
	"context"
	"fmt"
	"io"
	"log"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gogo/protobuf/proto"

	"dropbox/cputime"
	"dropbox/procfs"
	svclib_proto "dropbox/proto/build_tools/svclib"
)

type SvcCtlProcessor struct {
	lock     sync.RWMutex
	services map[string]*serviceDef
	verbose  bool
}

func NewSvcCtlProcessor(verbose bool) *SvcCtlProcessor {
	return &SvcCtlProcessor{
		services: make(map[string]*serviceDef),
		verbose:  verbose,
	}
}

func (s *SvcCtlProcessor) CreateBatch(ctx context.Context, req *svclib_proto.CreateBatchReq) (
	*svclib_proto.Empty, error) {
	s.lock.Lock()
	defer s.lock.Unlock()

	toAdd := req.Services
	prevLen := len(toAdd)
	for true {
		toAddNext := []*svclib_proto.Service{}
		createErrors := []error{}
		// TODO: This is possibly a stupid way to create services in dependency order. Don't
		// make RPC calls from the processors, please.
		for _, svc := range toAdd {
			if err := s.create(svc); err != nil {
				toAddNext = append(toAddNext, svc)
				createErrors = append(createErrors, err)
			}
		}

		if len(toAddNext) != 0 {
			// Some services need to still be added
			if len(toAddNext) == prevLen {
				reason := ""
				for _, err := range createErrors {
					reason += "\n" + err.Error()
				}
				return nil, fmt.Errorf(
					"Some services could not be added:" + reason)
			}
			toAdd = toAddNext
			prevLen = len(toAdd)
		} else {
			return &svclib_proto.Empty{}, nil
		}
	}
	return nil, nil
}

// stop and remove services. Doesn't try to do it in any particular order.
func (s *SvcCtlProcessor) RemoveBatch(ctx context.Context, req *svclib_proto.RemoveBatchReq) (
	*svclib_proto.Empty, error) {
	s.lock.Lock()
	defer s.lock.Unlock()
	for _, serviceName := range req.GetServiceNames() {
		if service, ok := s.services[serviceName]; !ok {
			return &svclib_proto.Empty{}, fmt.Errorf("Unrecognized service name %s\n", serviceName)
		} else {
			// note: Stop() is a no-op on stopped services
			if err := service.Stop(); err != nil {
				return &svclib_proto.Empty{}, fmt.Errorf("Error stopping service %s for removal. %s", serviceName, err)
			}
			delete(s.services, serviceName)
		}
	}
	return &svclib_proto.Empty{}, nil
}

// Must be called with controller lock held.
func (s *SvcCtlProcessor) create(svc *svclib_proto.Service) error {
	if _, ok := s.services[*svc.ServiceName]; ok {
		return fmt.Errorf("Duplicate service name")
	}

	svcDef, createErr := NewService(svc, s.services, s.verbose || svc.GetVerbose())
	if createErr != nil {
		return createErr
	}
	s.services[*svc.ServiceName] = svcDef
	return nil
}

func (s *SvcCtlProcessor) Start(stream svclib_proto.SvcCtl_StartServer) error {

	serviceNames := make([]*string, 0)
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		serviceNames = append(serviceNames, req.ServiceName)
	}

	svcs := make([]*serviceDef, 0)
	s.lock.RLock()
	for _, serviceName := range serviceNames {
		svc, ok := s.services[*serviceName]
		if !ok {
			return fmt.Errorf("Service name %s not found", *serviceName)
		}
		svcs = append(svcs, svc)
	}
	s.lock.RUnlock()

	starter := newTopologicalStarter(svcs)
	startErr := starter.Run()
	if startErr != nil {
		return startErr
	}

	sum := 0 * time.Second
	lfmt := "  %-76v %v"
	lines := make([]string, 0, 16)
	lines = append(lines, fmt.Sprintf("Started %v services", starter.Completed()))
	lines = append(lines, "Service startup critical path:")
	for _, svc := range starter.CriticalPath() {
		lines = append(lines, fmt.Sprintf(lfmt, svc.Key(), FmtDuration(svc.Duration())))
		sum = sum + svc.Duration()
	}
	lines = append(lines, fmt.Sprintf(lfmt, "Total", FmtDuration(sum)))
	log.Println(strings.Join(lines, "\n"))
	stream.SendAndClose(&svclib_proto.Empty{})
	return nil
}

func (s *SvcCtlProcessor) Status(ctx context.Context, req *svclib_proto.StatusReq) (
	*svclib_proto.StatusResp, error) {
	s.lock.RLock()
	defer s.lock.RUnlock()

	resp := new(svclib_proto.StatusResp)
	var serviceNames []string
	if len(req.ServiceNames) > 0 {
		serviceNames = append(serviceNames, req.ServiceNames...)
	} else {
		// If we don't specify a list of services to get status for, return status for everything
		for name := range s.services {
			serviceNames = append(serviceNames, name)
		}
	}

	for _, name := range serviceNames {
		svc, ok := s.services[name]
		if !ok {
			return nil, fmt.Errorf("Unknown service %s", name)
		}
		var failureMessage *svclib_proto.StatusResp_FailureMessage
		errors := svc.getSanitizerErrors()
		if len(errors) != 0 {
			msgType := svclib_proto.StatusResp_FailureMessage_HAS_RACES
			failureMessage = &svclib_proto.StatusResp_FailureMessage{
				Type: &msgType,
				Log:  proto.String(fmt.Sprintf("%d SANITIZER ERRORS FOUND:\n%s", len(errors), strings.Join(errors, "\n"))),
			}
		}
		status := svc.StateMachine.GetState()
		pid := svc.getPid()
		resp.SvcStatus = append(resp.SvcStatus, &svclib_proto.StatusResp_Status{
			ServiceName:     proto.String(name),
			Owner:           proto.String(svc.owner),
			StatusCode:      &status,
			NeedsRestart:    proto.Bool(svc.needsRestart()),
			LogFile:         proto.String(svc.getLogsPath()),
			Type:            &svc.ServiceType,
			StartDurationMs: proto.Int64(int64(svc.startDuration / time.Millisecond)),
			FailureMessage:  failureMessage,
			Pid:             proto.Int64(int64(pid)),
		})
	}

	return resp, nil
}

func (s *SvcCtlProcessor) Diagnostics(ctx context.Context, req *svclib_proto.DiagnosticsReq) (
	*svclib_proto.DiagnosticsResp, error) {
	s.lock.RLock()
	defer s.lock.RUnlock()

	resp := new(svclib_proto.DiagnosticsResp)
	var serviceNames []string
	if len(req.ServiceNames) > 0 {
		serviceNames = append(serviceNames, req.ServiceNames...)
	} else {
		// If we don't specify a list of services to get metrics for, return metrics for everything
		for name := range s.services {
			serviceNames = append(serviceNames, name)
		}
	}

	for _, name := range serviceNames {
		svc, ok := s.services[name]
		if !ok {
			return nil, fmt.Errorf("Unknown service %s", name)
		}

		pid := svc.getPid()
		totalCpuTime := time.Duration(0)
		totalRssMb := int64(0)
		hasErr := false

		descendents, err := procfs.GetProcessDescendents(pid)
		if err == nil {
			for _, pid := range descendents {

				cpuTime, err := cputime.CPUTime(pid)
				if err != nil {
					hasErr = true
					break
				}

				// we want to ignore ESRCH since it's non fatal:
				// when the pid retrieved by the GetProcessDescendents exits before
				// we manage to make the call for VszRssBytes.
				_, rss, err := procfs.GetVszRssBytes(pid)
				if err != nil && err != syscall.ESRCH {
					hasErr = true
					break
				}
				totalCpuTime += cpuTime
				totalRssMb += rss
			}
		}

		if hasErr {
			// better to fail loudly than have partially written values
			totalCpuTime = 0
			totalRssMb = 0
		}

		resp.SvcMetrics = append(resp.SvcMetrics, &svclib_proto.DiagnosticsResp_Metrics{
			ServiceName: proto.String(name),
			CpuTimeMs:   proto.Int64(int64(totalCpuTime / time.Millisecond)),
			RssMb:       proto.Int64(totalRssMb),
		})
	}

	return resp, nil
}

func (s *SvcCtlProcessor) Stop(ctx context.Context, req *svclib_proto.StopReq) (
	*svclib_proto.Empty, error) {
	s.lock.RLock()
	svc, ok := s.services[*req.ServiceName]
	s.lock.RUnlock()

	if !ok {
		return nil, fmt.Errorf("Service name %s not found", *req.ServiceName)
	} else {
		stopErr := svc.Stop()
		return &svclib_proto.Empty{}, stopErr
	}
}

func (s *SvcCtlProcessor) StopAll(ctx context.Context, empty *svclib_proto.Empty) (
	*svclib_proto.Empty, error) {
	s.lock.RLock()
	svcs := make([]*serviceDef, 0, len(s.services))
	for _, svc := range s.services {
		svcs = append(svcs, svc)
	}
	stopper := newTopologicalStopper(svcs)
	s.lock.RUnlock()
	return &svclib_proto.Empty{}, stopper.Run()
}
