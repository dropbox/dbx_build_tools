package main

import (
	"flag"
	"io/ioutil"
	"log"
	"net"
	"strconv"

	"google.golang.org/grpc"

	"dropbox/build_tools/svcctl"
	"dropbox/build_tools/svcctl/svclib"
	svclib_proto "dropbox/proto/build_tools/svclib"
)

func main() {
	var listenAddress string
	var verbose bool
	flag.StringVar(&listenAddress, "listen-address", "localhost:0", "Address to listen on")
	flag.BoolVar(&verbose, "verbose", false, "Verbose output for services")

	flag.Parse()

	lis, err := net.Listen("tcp", ":0")
	if err != nil {
		log.Fatal("Failed to listen", err)
	}
	port := lis.Addr().(*net.TCPAddr).Port

	log.Printf("Listening on port %d\n", port)
	if writeErr := ioutil.WriteFile(svclib.SvcdPortLocation, strconv.AppendInt(nil, int64(port), 10), 0644); writeErr != nil {
		log.Fatal(writeErr)
	}

	grpcServer := grpc.NewServer()
	svclib_proto.RegisterSvcCtlServer(grpcServer, svcctl.NewSvcCtlProcessor(verbose))

	if serveErr := grpcServer.Serve(lis); serveErr != nil {
		log.Fatal("Serve error:", serveErr)
	}
}
