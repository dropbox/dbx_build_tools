package svclib

import (
	"strconv"

	svclib_proto "dropbox/proto/build_tools/svclib"
)

func CmdHealthCheck(cmd string) *svclib_proto.HealthCheck {
	checkType := svclib_proto.HealthCheck_COMMAND
	return &svclib_proto.HealthCheck{
		Type: &checkType,
		Cmd: &svclib_proto.Command{
			Cmd: &cmd,
		},
	}
}

func HttpHealthCheck(addr string) *svclib_proto.HealthCheck {
	checkType := svclib_proto.HealthCheck_HTTP
	return &svclib_proto.HealthCheck{
		Type: &checkType,
		HttpHealthCheck: &svclib_proto.HttpHealthCheck{
			Url: &addr,
		},
	}
}

func HttpPortHealthCheck(port int) *svclib_proto.HealthCheck {
	return HttpHealthCheck("http://localhost:" + strconv.Itoa(port) + "/dbz/health")
}
