package main

import (
	"bufio"
	"dropbox/build_tools/gojunit"
	"dropbox/build_tools/junit"
	"encoding/json"
	"flag"
	"log"
	"os"
	"time"
)

func main() {
	log.SetFlags(log.Ldate | log.Ltime | log.Lshortfile)
	target := flag.String("target", "", "bazel target")
	flag.Parse()

	events := make([]gojunit.Event, 0)

	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		var event gojunit.Event
		bytes := scanner.Bytes()
		if eventErr := json.Unmarshal(scanner.Bytes(), &event); eventErr != nil {
			log.Printf("%s", bytes)
			log.Fatal(eventErr)
		}
		events = append(events, event)
	}
	if scanner.Err() != nil {
		log.Fatal(scanner.Err().Error())
	}

	junitTestCases, durationFl := gojunit.ParseEvents(*target+"/", events)
	duration := time.Duration(int(durationFl)) * time.Second

	xmlFile, xmlFileErr := os.OpenFile(os.Getenv("XML_OUTPUT_FILE"), os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0644)
	defer xmlFile.Close()
	if xmlFileErr != nil {
		log.Fatal(xmlFileErr.Error())
	}

	junit.OverwriteXMLDuration(nil, duration, *target, junitTestCases, xmlFile)
}
