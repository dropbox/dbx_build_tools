package svclib

import (
	"context"
	"fmt"
	"io/ioutil"
	"net"
	"sync"

	"google.golang.org/grpc"

	svclib_proto "dropbox/proto/build_tools/svclib"
)

type Service interface {
	Start() error
	Stop() error
	Remove() error
	Running() (bool, error)
	Status() (*svclib_proto.StatusResp_Status, error)
	Diagnostics() (*svclib_proto.DiagnosticsResp_Metrics, error)
	toProto() *svclib_proto.StartReq
	Name() string
}

type serviceImpl struct {
	client      svclib_proto.SvcCtlClient
	serviceName string
}

func (s *serviceImpl) Name() string {
	return s.serviceName
}

func (s *serviceImpl) toProto() *svclib_proto.StartReq {
	waitForHealthy := true
	return &svclib_proto.StartReq{
		ServiceName:    &s.serviceName,
		WaitForHealthy: &waitForHealthy, // ignored by server it always waits
	}
}

func multiStart(svcs []*svclib_proto.StartReq) error {
	client, err := getSvcCtlClient()
	if err != nil {
		return err
	}
	stream, err := client.Start(context.Background())
	if err != nil {
		return err
	}
	for _, svc := range svcs {
		err := stream.Send(svc)
		if err != nil {
			return err
		}
	}
	_, err = stream.CloseAndRecv()
	return err
}

func (s *serviceImpl) Start() error {
	return multiStart([]*svclib_proto.StartReq{s.toProto()})
}

func (s *serviceImpl) Stop() error {
	_, stopErr := s.client.Stop(
		context.Background(),
		&svclib_proto.StopReq{
			ServiceName: &s.serviceName,
		})
	return stopErr
}

func (s *serviceImpl) Remove() error {
	_, err := s.client.RemoveBatch(context.Background(), &svclib_proto.RemoveBatchReq{
		ServiceNames: []string{s.Name()},
	})
	return err
}

func (s *serviceImpl) Running() (bool, error) {
	status, err := s.Status()
	if err != nil {
		return false, err
	}
	return status.GetStatusCode() == svclib_proto.StatusResp_STARTED, nil
}

func (s *serviceImpl) Status() (*svclib_proto.StatusResp_Status, error) {
	status, stopErr := s.client.Status(
		context.Background(),
		&svclib_proto.StatusReq{
			ServiceNames: []string{s.serviceName},
		})
	if stopErr != nil {
		return nil, stopErr
	}
	if len(status.SvcStatus) != 1 {
		return nil, fmt.Errorf("Expected exactly one value in Status response, got %d",
			len(status.SvcStatus))
	}
	return status.SvcStatus[0], nil
}

func (s *serviceImpl) Diagnostics() (*svclib_proto.DiagnosticsResp_Metrics, error) {
	status, stopErr := s.client.Diagnostics(
		context.Background(),
		&svclib_proto.DiagnosticsReq{
			ServiceNames: []string{s.serviceName},
		})
	if stopErr != nil {
		return nil, stopErr
	}
	if len(status.SvcMetrics) != 1 {
		return nil, fmt.Errorf("Expected exactly one value in Metrics response, got %d",
			len(status.SvcMetrics))
	}
	return status.SvcMetrics[0], nil
}

var svcCtlClient svclib_proto.SvcCtlClient
var initLock sync.Mutex

func getSvcCtlClient() (svclib_proto.SvcCtlClient, error) {
	initLock.Lock()
	defer initLock.Unlock()
	if svcCtlClient != nil {
		return svcCtlClient, nil
	}
	bytes, readErr := ioutil.ReadFile(SvcdPortLocation)
	if readErr != nil {
		// file might not exist yet
		return nil, readErr
	}
	addr := fmt.Sprintf("localhost:%s", bytes)
	// TODO There is no correct handshake so it generates a server-side error message on
	// every startup that isn't necessary. Creating a file-based balancer would solve
	// this. Preflight-checking is a anti-pattern.
	if _, err := net.Dial("tcp", addr); err != nil {
		return nil, err
	}
	conn, err := grpc.Dial(addr, grpc.WithInsecure())
	if err != nil {
		return nil, err
	}
	svcCtlClient = svclib_proto.NewSvcCtlClient(conn)
	return svcCtlClient, nil
}

func SvcCtlListening() bool {
	var err error
	_, err = getSvcCtlClient()
	return err == nil
}

func statusAll() (
	svclib_proto.SvcCtlClient,
	[]*svclib_proto.StatusResp_Status,
	error) {

	client, err := getSvcCtlClient()
	if err != nil {
		return nil, nil, err
	}
	statusResp, statusErr := client.Status(context.Background(), &svclib_proto.StatusReq{})
	if statusErr != nil {
		return nil, nil, statusErr
	}
	return client, statusResp.GetSvcStatus(), nil
}

func ListServices() ([]Service, error) {
	client, statusList, err := statusAll()
	if err != nil {
		return nil, err
	}
	services := make([]Service, 0, len(statusList))
	for _, status := range statusList {
		services = append(services, &serviceImpl{
			client:      client,
			serviceName: status.GetServiceName(),
		})
	}
	return services, nil
}

func DiagnosticsAll() ([]*svclib_proto.DiagnosticsResp_Metrics, error) {
	client, err := getSvcCtlClient()
	if err != nil {
		return nil, err
	}
	metricsResp, metricsErr := client.Diagnostics(context.Background(), &svclib_proto.DiagnosticsReq{})
	if metricsErr != nil {
		return nil, metricsErr
	}
	return metricsResp.GetSvcMetrics(), nil
}

func StatusAll() ([]*svclib_proto.StatusResp_Status, error) {
	_, status, err := statusAll()
	return status, err
}

// We don't check if a service is actually registered on the service controller here.
func GetService(serviceName string) (Service, error) {
	client, err := getSvcCtlClient()
	if err != nil {
		return nil, err
	}
	return &serviceImpl{
		client:      client,
		serviceName: serviceName,
	}, nil
}

func StartAll() error {
	services, listErr := ListServices()
	if listErr != nil {
		return listErr
	}
	reqs := make([]*svclib_proto.StartReq, 0)
	for _, service := range services {
		reqs = append(reqs, service.toProto())
	}
	return multiStart(reqs)
}

func StopAll() error {
	client, err := getSvcCtlClient()
	if err != nil {
		return err
	}
	_, err = client.StopAll(context.Background(), &svclib_proto.Empty{})
	return err
}

func CreateServices(createReq *svclib_proto.CreateBatchReq) ([]Service, error) {
	client, err := getSvcCtlClient()
	if err != nil {
		return nil, err
	}
	if _, createErr := client.CreateBatch(context.Background(), createReq); createErr != nil {
		return nil, createErr
	}

	// Create controllable Service instances.
	var services []Service
	for _, svc := range createReq.Services {
		created, createErr := GetService(*svc.ServiceName)
		if createErr != nil {
			return nil, createErr
		}
		services = append(services, created)
	}
	return services, nil
}

// a wrapper around CreateServices for creating just one service
func CreateService(service *svclib_proto.Service) (Service, error) {
	created, err := CreateServices(&svclib_proto.CreateBatchReq{
		Services: []*svclib_proto.Service{
			service,
		},
	})
	if err != nil {
		return nil, err
	}
	return created[0], nil
}
